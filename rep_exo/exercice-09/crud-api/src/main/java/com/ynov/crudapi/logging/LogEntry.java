package com.ynov.crudapi.logging;

/** Payload sent to the logs API (POST /api/v1/logs). */
public record LogEntry(String message, String source, String timestamp, LogLevel level) {
}
