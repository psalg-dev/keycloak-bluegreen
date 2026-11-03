package demo.legacy;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;

/**
 * Production trust setting (application.yaml: only the pod subnet is an internal proxy). This test connects from
 * loopback, i.e. like a client that reaches the app without the ingress: its X-Forwarded-* must not pick the issuer.
 * Also proves the CIDR form of internal-proxies is applied at all (a mis-parsed value would trust nobody or everybody;
 * AuthCodeFlowTest covers "trusts the configured CIDR").
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"LEGACY_USER_PASSWORD=pw-test", "LEGACY_CLIENT_SECRET=secret-test", "legacy.users=1"})
class UntrustedPeerTest {

    @LocalServerPort
    int port;

    @Test
    void forwardedHostFromANonProxyPeerIsIgnored() throws Exception {
        assertThat(AuthCodeFlowTest.issuer(port, "X-Forwarded-Host", "legacy-net1.localtest.me", "X-Forwarded-Proto", "https",
                "Forwarded", "host=evil.example;proto=http")).isEqualTo("http://localhost:" + port);
    }
}
