package fr.ynov.logapi;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

public record LogEntry(
        @NotBlank String message,
        @NotBlank String source,
        @NotBlank String timestamp,
        @NotNull LogLevel level
) {
}
