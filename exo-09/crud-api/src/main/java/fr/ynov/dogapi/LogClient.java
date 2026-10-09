package fr.ynov.dogapi;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

import java.util.Map;

/**
 * Client HTTP (RestTemplate) qui envoie les logs à l'API de logs.
 */
@Component
public class LogClient {

    private static final Logger LOG = LoggerFactory.getLogger(LogClient.class);

    private final RestTemplate restTemplate;
    private final String url;

    public LogClient(@Value("${logs.api.url}") String url) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(2000);
        factory.setReadTimeout(2000);
        this.restTemplate = new RestTemplate(factory);
        this.url = url;
    }

    public void send(String message, String source, String timestamp, String level) {
        Map<String, String> body = Map.of(
                "message", message,
                "source", source,
                "timestamp", timestamp,
                "level", level);
        try {
            restTemplate.postForEntity(url, body, Void.class);
        } catch (Exception e) {
            // L'API CRUD doit continuer à fonctionner même si l'API de logs est indisponible
            LOG.warn("Impossible d'envoyer le log à {} : {}", url, e.getMessage());
        }
    }
}
