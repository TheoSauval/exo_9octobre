package fr.ynov.dogapi;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.time.Instant;

/**
 * Après chaque appel à /api/**, envoie un log à l'API de logs :
 * INFO pour 2xx/3xx, WARN pour 4xx, ERR pour 5xx.
 */
@Component
public class LoggingInterceptor implements HandlerInterceptor {

    private final LogClient logClient;

    public LoggingInterceptor(LogClient logClient) {
        this.logClient = logClient;
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler, Exception ex) {
        int status = response.getStatus();
        String level = status >= 500 ? "ERR" : status >= 400 ? "WARN" : "INFO";

        Object error = request.getAttribute(ApiExceptionHandler.ERROR_MESSAGE);
        Object errorTime = request.getAttribute(ApiExceptionHandler.ERROR_TIMESTAMP);

        String message = error != null ? error.toString() : "HTTP " + status;
        String timestamp = errorTime != null ? errorTime.toString() : Instant.now().toString();
        String source = "[CrudAPI] " + request.getMethod() + " " + request.getRequestURI();

        logClient.send(message, source, timestamp, level);
    }
}
