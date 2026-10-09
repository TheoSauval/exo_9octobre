package fr.ynov.dogapi;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.ErrorResponse;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

import java.time.Instant;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Transforme les exceptions en réponses JSON et mémorise le message d'erreur
 * et l'instant où il a été levé, pour que LoggingInterceptor l'envoie à l'API de logs.
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    static final String ERROR_MESSAGE = "log.errorMessage";
    static final String ERROR_TIMESTAMP = "log.errorTimestamp";

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<Map<String, Object>> handleStatus(ResponseStatusException ex, HttpServletRequest request) {
        return build(ex.getStatusCode(), ex.getReason(), request);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<Map<String, Object>> handleValidation(MethodArgumentNotValidException ex, HttpServletRequest request) {
        String message = ex.getBindingResult().getFieldErrors().stream()
                .map(e -> e.getField() + " : " + e.getDefaultMessage())
                .collect(Collectors.joining(", "));
        return build(HttpStatus.BAD_REQUEST, "Requête invalide (" + message + ")", request);
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<Map<String, Object>> handleUnreadable(HttpMessageNotReadableException ex, HttpServletRequest request) {
        return build(HttpStatus.BAD_REQUEST, "Corps JSON illisible", request);
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> handleOther(Exception ex, HttpServletRequest request) {
        if (ex instanceof ErrorResponse errorResponse) {
            return build(errorResponse.getStatusCode(), ex.getMessage(), request);
        }
        return build(HttpStatus.INTERNAL_SERVER_ERROR, ex.getClass().getSimpleName() + " : " + ex.getMessage(), request);
    }

    private ResponseEntity<Map<String, Object>> build(HttpStatusCode status, String message, HttpServletRequest request) {
        String msg = message == null ? "Erreur" : message;
        request.setAttribute(ERROR_MESSAGE, msg);
        request.setAttribute(ERROR_TIMESTAMP, Instant.now().toString());
        return ResponseEntity.status(status).body(Map.<String, Object>of("status", status.value(), "error", msg));
    }
}
