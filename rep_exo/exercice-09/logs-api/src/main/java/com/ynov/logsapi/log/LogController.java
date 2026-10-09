package com.ynov.logsapi.log;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/v1/logs")
public class LogController {

    private final LogFileRepository logRepository;

    public LogController(LogFileRepository logRepository) {
        this.logRepository = logRepository;
    }

    /** All logs, optionally filtered by level: GET /api/v1/logs?level=ERR */
    @GetMapping
    public List<LogEntry> findAll(@RequestParam(required = false) LogLevel level) {
        List<LogEntry> logs = logRepository.findAll();
        return level == null ? logs : logs.stream().filter(log -> log.level() == level).toList();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public LogEntry create(@Valid @RequestBody LogEntry entry) {
        return logRepository.save(entry);
    }
}
