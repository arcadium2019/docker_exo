package com.ynov.logsapi.log;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Repository;
import tools.jackson.databind.json.JsonMapper;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.List;

/**
 * Stores logs in a JSON Lines file (one JSON object per line).
 * The file lives in a Docker volume so logs survive container re-creation.
 */
@Repository
public class LogFileRepository {

    private final Path file;
    private final JsonMapper jsonMapper;

    public LogFileRepository(@Value("${logs.file}") Path file, JsonMapper jsonMapper) throws IOException {
        this.file = file;
        this.jsonMapper = jsonMapper;
        if (file.getParent() != null) {
            Files.createDirectories(file.getParent());
        }
    }

    public synchronized LogEntry save(LogEntry entry) {
        try {
            Files.writeString(file, jsonMapper.writeValueAsString(entry) + System.lineSeparator(),
                    StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            return entry;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public synchronized List<LogEntry> findAll() {
        if (!Files.exists(file)) {
            return List.of();
        }
        try {
            return Files.readAllLines(file, StandardCharsets.UTF_8).stream()
                    .filter(line -> !line.isBlank())
                    .map(line -> jsonMapper.readValue(line, LogEntry.class))
                    .toList();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
