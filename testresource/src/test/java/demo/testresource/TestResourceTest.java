package demo.testresource;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Date;
import java.util.concurrent.atomic.AtomicInteger;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Resource server against a stub Keycloak (JDK HttpServer: JWKS + introspection), the system boundary. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"TESTRESOURCE_SECRET=rs-test", "spring.ssl.bundle.pem.demo-ca.truststore.certificate=classpath:test-ca.crt"})
@ExtendWith(OutputCaptureExtension.class)
class TestResourceTest {

    static final RSAKey KEY = rsa("k1");
    static final HttpServer KEYCLOAK = stubKeycloak();
    static final AtomicInteger introspections = new AtomicInteger();
    static volatile int introspectStatus;
    static volatile String introspectBody;
    static volatile String introspectAuth;

    @DynamicPropertySource
    static void keycloak(DynamicPropertyRegistry r) {
        r.add("demo.issuer", () -> "http://127.0.0.1:" + KEYCLOAK.getAddress().getPort() + "/{net}");
    }

    @LocalServerPort
    int port;

    final HttpClient http = HttpClient.newHttpClient();

    @Test
    void jwtFromATrustedIssuerIsAccepted() throws Exception {
        HttpResponse<String> r = get("/api/jwt", jwt(issuer("net1"), KEY));
        assertThat(r.statusCode()).isEqualTo(200);
        assertThat(r.body()).isEqualTo("{\"sub\":\"user0042\",\"iss\":\"" + issuer("net1") + "\",\"tenant\":\"t2\"}");
    }

    @Test
    void jwtFromAnUnknownIssuerIsRejected(CapturedOutput out) throws Exception {
        assertThat(get("/api/jwt", jwt("https://evil.example/realms/demo", KEY)).statusCode()).isEqualTo(401);
        assertThat(out).contains("\"event\":\"request\",\"path\":\"/api/jwt\",\"status\":401");
    }

    @Test
    void jwtWithABadSignatureIsRejected(CapturedOutput out) throws Exception {
        assertThat(get("/api/jwt", jwt(issuer("net1"), rsa("k1"))).statusCode()).isEqualTo(401); // same kid, other key
        assertThat(out).contains("Invalid signature");
    }

    @Test
    void introspectAsksKeycloakOnEveryRequest() throws Exception {
        stub(200, "{\"active\":true,\"sub\":\"user0042\"}");
        String token = jwt(issuer("net1"), KEY);
        int before = introspections.get();
        assertThat(get("/api/introspect", token).body())
                .isEqualTo("{\"active\":true,\"sub\":\"user0042\",\"iss\":\"" + issuer("net1") + "\"}");
        assertThat(get("/api/introspect", token).statusCode()).isEqualTo(200);
        assertThat(introspections.get() - before).isEqualTo(2); // no cache
        assertThat(introspectAuth).isEqualTo("Basic " + Base64.getEncoder().encodeToString("testresource:rs-test".getBytes()));
    }

    @Test
    void introspectInactiveIs401(CapturedOutput out) throws Exception {
        stub(200, "{\"active\":false}");
        assertThat(get("/api/introspect", jwt(issuer("net2"), KEY)).statusCode()).isEqualTo(401);
        assertThat(out).contains("\"event\":\"introspection\",\"issuer\":\"" + issuer("net2")
                + "\",\"http_status\":200,\"active\":false");
    }

    @Test
    void introspectionEndpointDownIs503(CapturedOutput out) throws Exception {
        stub(503, "<html>no healthy upstream</html>");
        assertThat(get("/api/introspect", jwt(issuer("net1"), KEY)).statusCode()).isEqualTo(503);
        assertThat(out).contains("\"http_status\":503,\"active\":null").contains("\"error\":\"5xx\"}")
                .contains("\"event\":\"request\",\"path\":\"/api/introspect\",\"status\":503");
    }

    @Test
    void introspectRejectsUntrustedIssuersWithoutCallingThem() throws Exception {
        int before = introspections.get();
        assertThat(get("/api/introspect", jwt("https://evil.example/realms/demo", KEY)).statusCode()).isEqualTo(401);
        assertThat(get("/api/introspect", "not-a-jwt").statusCode()).isEqualTo(401);
        assertThat(introspections.get()).isEqualTo(before);
    }

    HttpResponse<String> get(String path, String token) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create("http://localhost:" + port + path))
                .header("Authorization", "Bearer " + token).build(), HttpResponse.BodyHandlers.ofString());
    }

    static void stub(int status, String body) {
        introspectStatus = status;
        introspectBody = body;
    }

    static String issuer(String net) {
        return "http://127.0.0.1:" + KEYCLOAK.getAddress().getPort() + "/" + net;
    }

    static String jwt(String iss, RSAKey key) throws Exception {
        SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
                new JWTClaimsSet.Builder().issuer(iss).subject("user0042").claim("tenant", "t2")
                        .issueTime(new Date()).expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
        jwt.sign(new RSASSASigner(key));
        return jwt.serialize();
    }

    static RSAKey rsa(String kid) {
        try {
            return new RSAKeyGenerator(2048).keyID(kid).generate();
        }
        catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    static HttpServer stubKeycloak() {
        try {
            HttpServer s = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            s.createContext("/", ex -> {
                String path = ex.getRequestURI().getPath();
                if (path.endsWith("/protocol/openid-connect/certs")) {
                    reply(ex, 200, new JWKSet(KEY.toPublicJWK()).toString());
                }
                else if (path.endsWith("/protocol/openid-connect/token/introspect")) {
                    introspections.incrementAndGet();
                    introspectAuth = ex.getRequestHeaders().getFirst("Authorization");
                    reply(ex, introspectStatus, introspectBody);
                }
                else {
                    reply(ex, 404, "{}");
                }
            });
            s.start();
            return s;
        }
        catch (IOException e) {
            throw new IllegalStateException(e);
        }
    }

    static void reply(HttpExchange ex, int status, String body) throws IOException {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", body.startsWith("{") ? "application/json" : "text/html");
        ex.sendResponseHeaders(status, b.length);
        ex.getResponseBody().write(b);
        ex.close();
    }
}
