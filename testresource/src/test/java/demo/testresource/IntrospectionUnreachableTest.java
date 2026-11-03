package demo.testresource;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.ServerSocket;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Keycloak not even accepting connections: introspection failure "connect", 503 to the caller. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"TESTRESOURCE_SECRET=rs-test", "spring.ssl.bundle.pem.demo-ca.truststore.certificate=classpath:test-ca.crt"})
@ExtendWith(OutputCaptureExtension.class)
class IntrospectionUnreachableTest {

    static final int CLOSED_PORT = closedPort();

    @DynamicPropertySource
    static void keycloak(DynamicPropertyRegistry r) {
        r.add("demo.issuer", () -> "http://127.0.0.1:" + CLOSED_PORT + "/{net}");
    }

    @LocalServerPort
    int port;

    @Test
    void connectFailureIs503(CapturedOutput out) throws Exception {
        String token = TestResourceTest.jwt("http://127.0.0.1:" + CLOSED_PORT + "/net1", TestResourceTest.KEY);
        HttpResponse<String> r = HttpClient.newHttpClient().send(HttpRequest.newBuilder(
                URI.create("http://localhost:" + port + "/api/introspect")).header("Authorization", "Bearer " + token).build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(r.statusCode()).isEqualTo(503);
        assertThat(out).contains("\"http_status\":0,\"active\":null").contains("\"error\":\"connect\"}");
    }

    static int closedPort() {
        try (ServerSocket s = new ServerSocket(0)) {
            return s.getLocalPort();
        }
        catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
