package com.ynov.crudapi.logging;

import com.ynov.crudapi.error.GlobalExceptionHandler;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.time.Instant;

/**
 * Sends one log per API call to the logs API:
 * 2xx/3xx -> INFO, 4xx -> WARN, 5xx -> ERR.
 */
@Component
public class RequestLoggingInterceptor implements HandlerInterceptor {

    private final LogClient logClient;

    public RequestLoggingInterceptor(LogClient logClient) {
        this.logClient = logClient;
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler, Exception ex) {
        int status = response.getStatus();
        String source = "[CrudAPI] " + request.getMethod() + " " + request.getRequestURI();

        String message = (String) request.getAttribute(GlobalExceptionHandler.ERROR_MESSAGE_ATTRIBUTE);
        if (message == null) {
            message = ex != null ? ex.getMessage() : status + " " + reasonPhrase(status);
        }

        Instant timestamp = (Instant) request.getAttribute(GlobalExceptionHandler.ERROR_TIMESTAMP_ATTRIBUTE);
        if (timestamp == null) {
            timestamp = Instant.now();
        }

        logClient.send(new LogEntry(message, source, timestamp.toString(), levelOf(status)));
    }

    private static LogLevel levelOf(int status) {
        if (status >= 500) {
            return LogLevel.ERR;
        }
        return status >= 400 ? LogLevel.WARN : LogLevel.INFO;
    }

    private static String reasonPhrase(int status) {
        HttpStatus httpStatus = HttpStatus.resolve(status);
        return httpStatus != null ? httpStatus.getReasonPhrase() : "";
    }
}
