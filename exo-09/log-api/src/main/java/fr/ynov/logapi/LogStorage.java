package fr.ynov.logapi;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;

/**
 * Stocke les logs dans un fichier JSON Lines (un log JSON par ligne).
 */
@Component
public class LogStorage {

    private final Path file;
    private final ObjectMapper mapper;

    public LogStorage(@Value("${logs.file:/data/logs.jsonl}") String file, ObjectMapper mapper) throws IOException {
        this.file = Path.of(file);
        this.mapper = mapper;
        if (this.file.getParent() != null) {
            Files.createDirectories(this.file.getParent());
        }
    }

    public synchronized void append(LogEntry entry) {
        try {
            String line = mapper.writeValueAsString(entry) + System.lineSeparator();
            Files.writeString(file, line, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public synchronized List<LogEntry> findAll() {
        List<LogEntry> logs = new ArrayList<>();
        if (!Files.exists(file)) {
            return logs;
        }
        try {
            for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
                if (!line.isBlank()) {
                    logs.add(mapper.readValue(line, LogEntry.class));
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return logs;
    }
}
