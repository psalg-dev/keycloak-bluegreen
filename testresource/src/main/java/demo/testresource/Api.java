package demo.testresource;

import java.net.ConnectException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.net.http.HttpConnectTimeoutException;
import java.net.http.HttpTimeoutException;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

import jakarta.servlet.http.HttpServletRequest;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ssl.SslBundles;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.http.client.support.BasicAuthenticationInterceptor;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.introspection.BadOpaqueTokenException;
import org.springframework.security.oauth2.server.resource.introspection.OAuth2IntrospectionException;
import org.springframework.security.oauth2.server.resource.introspection.OpaqueTokenIntrospector;
import org.springframework.security.oauth2.server.resource.introspection.SpringOpaqueTokenIntrospector;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClientResponseException;
import org.springframework.web.client.RestTemplate;

@RestController
class Api {

    /** issuer -> introspector of that issuer, as client `testresource`. No cache: every request asks Keycloak. */
    private final Map<String, OpaqueTokenIntrospector> introspectors = new HashMap<>();

    Api(@Value("${demo.issuer}") String issuerTemplate, @Value("${TESTRESOURCE_SECRET}") String secret, SslBundles bundles) {
        RestTemplate keycloak = TestResourceApplication.keycloakClient(bundles);
        keycloak.getInterceptors().add(new BasicAuthenticationInterceptor("testresource", secret));
        for (String net : TestResourceApplication.NETS) {
            String iss = TestResourceApplication.issuer(issuerTemplate, net);
            introspectors.put(iss, new SpringOpaqueTokenIntrospector(iss + "/protocol/openid-connect/token/introspect", keycloak));
        }
    }

    static String bearer(HttpServletRequest req) {
        String h = req.getHeader(HttpHeaders.AUTHORIZATION);
        return h != null && h.regionMatches(true, 0, "Bearer ", 0, 7) ? h.substring(7).trim() : null;
    }

    @GetMapping("/api/jwt")
    Map<String, Object> jwt(@AuthenticationPrincipal Jwt jwt) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("sub", jwt.getSubject());
        m.put("iss", jwt.getClaimAsString("iss"));
        m.put("tenant", jwt.getClaimAsString("tenant"));
        return m;
    }

    /**
     * Opaque-token style validation of the bearer token at its issuer's introspection endpoint. The token is a JWT, so
     * its iss (read unverified) picks the endpoint; introspection does the verification. Only the two trusted issuers
     * are ever called. 200 active / 401 inactive or unusable token / 503 introspection itself failed.
     */
    @GetMapping("/api/introspect")
    ResponseEntity<Map<String, Object>> introspect(HttpServletRequest req) {
        String token = bearer(req);
        if (token == null) {
            return fail(req, 401, "missing_token");
        }
        String iss = (String) Events.unverifiedClaims(token).get("iss");
        OpaqueTokenIntrospector introspector = iss == null ? null : introspectors.get(iss);
        if (introspector == null) {
            return fail(req, 401, "untrusted_issuer");
        }
        long t0 = System.nanoTime();
        try {
            OAuth2AuthenticatedPrincipal p = introspector.introspect(token);
            Events.log("introspection", "issuer", iss, "http_status", 200, "active", true, "latency_ms", Events.ms(t0), "error", null);
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("active", true);
            m.put("sub", p.getAttribute("sub"));
            m.put("iss", iss);
            return ResponseEntity.ok(m);
        }
        catch (BadOpaqueTokenException inactive) {
            Events.log("introspection", "issuer", iss, "http_status", 200, "active", false, "latency_ms", Events.ms(t0), "error", null);
            return fail(req, 401, "inactive");
        }
        catch (OAuth2IntrospectionException e) {
            int http = httpStatus(e);
            String error = classify(e, http);
            Events.log("introspection", "issuer", iss, "http_status", http, "active", null, "latency_ms", Events.ms(t0), "error", error);
            return fail(req, 503, error);
        }
    }

    private static ResponseEntity<Map<String, Object>> fail(HttpServletRequest req, int status, String error) {
        req.setAttribute(TestResourceApplication.ERROR, error);
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("active", status == 401 ? false : null);
        m.put("error", error);
        return ResponseEntity.status(status).body(m);
    }

    /** HTTP status of the introspection response; 0 when there was none (connect failure, timeout). */
    static int httpStatus(Throwable e) {
        for (Throwable c = e; c != null; c = c.getCause()) {
            if (c instanceof RestClientResponseException r) {
                return r.getStatusCode().value();
            }
        }
        return 0;
    }

    static String classify(Throwable e, int http) {
        if (http >= 500) {
            return "5xx";
        }
        if (http > 0) {
            return "http_" + http; // e.g. 401: Keycloak does not know the testresource client (yet)
        }
        for (Throwable c = e; c != null; c = c.getCause()) {
            if (c instanceof HttpConnectTimeoutException || c instanceof ConnectException || c instanceof UnknownHostException) {
                return "connect";
            }
            if (c instanceof HttpTimeoutException || c instanceof SocketTimeoutException) {
                return "timeout";
            }
        }
        return e.getMessage();
    }
}
