package fr.ynov.logapi;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/logs")
public class LogController {

    private final LogStorage storage;

    public LogController(LogStorage storage) {
        this.storage = storage;
    }

    @GetMapping
    public List<LogEntry> findAll() {
        return storage.findAll();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public LogEntry create(@Valid @RequestBody LogEntry entry) {
        storage.append(entry);
        return entry;
    }
}
