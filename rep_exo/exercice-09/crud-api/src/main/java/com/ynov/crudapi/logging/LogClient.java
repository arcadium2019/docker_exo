package com.ynov.crudapi.logging;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;

/**
 * HTTP client of the logs API. Calls are asynchronous and failures are swallowed:
 * the CRUD API must keep working even if the logs API is down.
 */
@Component
public class LogClient {

    private static final Logger LOGGER = LoggerFactory.getLogger(LogClient.class);

    private final RestTemplate restTemplate;
    private final String logsUrl;

    public LogClient(@Value("${logs-api.url}") String logsApiUrl) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(Duration.ofSeconds(2));
        requestFactory.setReadTimeout(Duration.ofSeconds(2));
        this.restTemplate = new RestTemplate(requestFactory);
        this.logsUrl = logsApiUrl + "/api/v1/logs";
    }

    @Async
    public void send(LogEntry entry) {
        try {
            restTemplate.postForEntity(logsUrl, entry, Void.class);
        } catch (RestClientException e) {
            LOGGER.warn("Unable to send log to {}: {}", logsUrl, e.getMessage());
        }
    }
}
