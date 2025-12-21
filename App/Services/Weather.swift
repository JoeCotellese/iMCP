// ABOUTME: WeatherKit MCP service providing current conditions and forecasts.
// ABOUTME: Wraps Apple WeatherKit with timeout protection for reliability.

import CoreLocation
import Foundation
import OSLog
import Ontology
import WeatherKit

private let log = Logger.service("weather")

/// Timeout duration for WeatherKit API calls (30 seconds).
private let weatherTimeout: Duration = .seconds(30)

/// Error thrown when a WeatherKit operation exceeds the timeout.
struct WeatherTimeoutError: Error, LocalizedError {
    var errorDescription: String? {
        "Weather request timed out. WeatherKit may be unavailable or experiencing authentication issues."
    }
}

final class WeatherService: Service {
    static let shared = WeatherService()

    private let weatherService = WeatherKit.WeatherService.shared

    /// Executes a WeatherKit operation with timeout protection.
    private func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: weatherTimeout)
                throw WeatherTimeoutError()
            }

            guard let result = try await group.next() else {
                throw WeatherTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    var tools: [Tool] {
        Tool(
            name: "weather_current",
            description:
                "Get current weather for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(),
                    "longitude": .number(),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Current Weather",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case let .double(latitude) = arguments["latitude"],
                case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }

            let location = CLLocation(latitude: latitude, longitude: longitude)
            log.info("Fetching current weather for \(latitude), \(longitude)")
            let currentWeather = try await self.withTimeout {
                try await self.weatherService.weather(for: location, including: .current)
            }

            return WeatherConditions(currentWeather)
        }

        Tool(
            name: "weather_daily",
            description: "Get daily weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(),
                    "longitude": .number(),
                    "days": .integer(
                        description: "Number of forecast days (max 10)",
                        default: 7,
                        minimum: 1,
                        maximum: 10
                    ),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Daily Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case let .double(latitude) = arguments["latitude"],
                case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }

            var days: Int = 7
            if case let .int(daysRequested) = arguments["days"] {
                days = daysRequested
            } else if case let .double(daysRequested) = arguments["days"] {
                days = Int(daysRequested)
            }
            days = days.clamped(to: 1...10)

            let location = CLLocation(latitude: latitude, longitude: longitude)
            log.info("Fetching daily forecast for \(latitude), \(longitude)")
            let dailyForecast = try await self.withTimeout {
                try await self.weatherService.weather(for: location, including: .daily)
            }

            return dailyForecast.prefix(days).map { WeatherForecast($0) }
        }

        Tool(
            name: "weather_hourly",
            description: "Get hourly weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(),
                    "longitude": .number(),
                    "hours": .integer(
                        description: "Number of hours to forecast",
                        default: 24,
                        minimum: 1,
                        maximum: 240
                    ),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Hourly Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case let .double(latitude) = arguments["latitude"],
                case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }

            let hours: Int
            switch arguments["hours"] {
            case let .int(hoursRequested):
                hours = min(240, max(1, hoursRequested))
            case let .double(hoursRequested):
                hours = Int(min(240, max(1, hoursRequested)))
            default:
                hours = 24
            }

            let location = CLLocation(latitude: latitude, longitude: longitude)
            log.info("Fetching hourly forecast for \(latitude), \(longitude)")
            let hourlyForecasts = try await self.withTimeout {
                try await self.weatherService.weather(for: location, including: .hourly)
            }

            return hourlyForecasts.prefix(hours).map { WeatherForecast($0) }
        }

        Tool(
            name: "weather_minute",
            description: "Get minute-by-minute weather forecast for a location",
            inputSchema: .object(
                properties: [
                    "latitude": .number(),
                    "longitude": .number(),
                    "minutes": .integer(
                        description: "Number of minutes to forecast",
                        default: 60,
                        minimum: 1,
                        maximum: 120
                    ),
                ],
                required: ["latitude", "longitude"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Minute-by-Minute Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case let .double(latitude) = arguments["latitude"],
                case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }

            var minutes: Int = 60
            if case let .int(minutesRequested) = arguments["minutes"] {
                minutes = minutesRequested
            } else if case let .double(minutesRequested) = arguments["minutes"] {
                minutes = Int(minutesRequested)
            }
            minutes = minutes.clamped(to: 1...120)

            let location = CLLocation(latitude: latitude, longitude: longitude)
            log.info("Fetching minute-by-minute forecast for \(latitude), \(longitude)")
            guard
                let minuteByMinuteForecast = try await self.withTimeout({
                    try await self.weatherService.weather(for: location, including: .minute)
                })
            else {
                throw NSError(
                    domain: "WeatherServiceError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No minute-by-minute forecast available"]
                )
            }

            return minuteByMinuteForecast.prefix(minutes).map { WeatherForecast($0) }
        }
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}
