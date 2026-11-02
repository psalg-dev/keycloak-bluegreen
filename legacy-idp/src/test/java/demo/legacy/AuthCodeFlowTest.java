package demo.legacy;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.CookieManager;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/** Drives the real auth-code + PKCE flow over HTTP, the way Keycloak's broker and a browser do. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"LEGACY_USER_PASSWORD=pw-test", "LEGACY_CLIENT_SECRET=secret-test", "legacy.users=50"})
class AuthCodeFlowTest {

    static final String REDIRECT = "https://kc-net1.localtest.me/keycloak/realms/demo/broker/legacy-net1/endpoint";
    static final JsonMapper JSON = JsonMapper.builder().build();

    @LocalServerPort
    int port;

    final HttpClient http = HttpClient.newBuilder().cookieHandler(new CookieManager())
            .followRedirects(HttpClient.Redirect.NEVER).build();

    @Test
    void authCodeFlowYieldsIdTokenWithLegacyClaims() throws Exception {
        String verifier = "v".repeat(50);
        String challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(
                MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII)));
        String authorize = base() + "/oauth2/authorize?" + form(Map.of("response_type", "code",
                "client_id", "keycloak-broker", "scope", "openid", "state", "s1", "redirect_uri", REDIRECT,
                "code_challenge", challenge, "code_challenge_method", "S256"));

        HttpResponse<String> r = get(authorize);
        assertThat(r.headers().firstValue("location")).hasValueSatisfying(l -> assertThat(l).endsWith("/login"));

        String csrf = find(get(base() + "/login").body(), "name=\"_csrf\"[^>]*value=\"([^\"]+)\"");
        r = post(base() + "/login", form(Map.of("username", "user0042", "password", "pw-test", "_csrf", csrf)), null);
        r = get(r.headers().firstValue("location").orElseThrow()); // saved authorize request
        String callback = r.headers().firstValue("location").orElseThrow();
        assertThat(callback).startsWith(REDIRECT + "?code=").contains("state=s1");

        String code = find(callback, "code=([^&]+)");
        JsonNode tokens = JSON.readTree(post(base() + "/oauth2/token", form(Map.of("grant_type", "authorization_code",
                "code", code, "redirect_uri", REDIRECT, "code_verifier", verifier)),
                "Basic " + b64("keycloak-broker:secret-test")).body());
        JsonNode id = JSON.readTree(Base64.getUrlDecoder().decode(tokens.get("id_token").asString().split("\\.")[1]));

        assertThat(id.get("sub").asString()).isEqualTo("user0042");
        assertThat(id.get("preferred_username").asString()).isEqualTo("user0042");
        assertThat(id.get("email").asString()).isEqualTo("user0042@legacy.example");
        assertThat(id.get("tenant").asString()).isEqualTo("t2");
        assertThat(tokens.get("refresh_token")).isNotNull();
    }

    @Test
    void issuerFollowsForwardedHostSoOneInstanceServesBothNetworks() throws Exception {
        for (String host : new String[] {"legacy-net1.localtest.me", "legacy-net2.localtest.me"}) {
            HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create(base() + "/.well-known/openid-configuration"))
                    .header("X-Forwarded-Host", host).header("X-Forwarded-Proto", "https").build(),
                    HttpResponse.BodyHandlers.ofString());
            assertThat(JSON.readTree(r.body()).get("issuer").asString()).isEqualTo("https://" + host);
        }
    }

    String base() {
        return "http://localhost:" + port;
    }

    /** Like a browser: without Accept text/html the server answers 401 instead of redirecting to /login. */
    HttpResponse<String> get(String url) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(url)).header("Accept", "text/html").build(),
                HttpResponse.BodyHandlers.ofString());
    }

    HttpResponse<String> post(String url, String body, String auth) throws Exception {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(url))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(body));
        if (auth != null) {
            b.header("Authorization", auth);
        }
        return http.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }

    static String form(Map<String, String> params) {
        return params.entrySet().stream()
                .map(e -> e.getKey() + "=" + URLEncoder.encode(e.getValue(), StandardCharsets.UTF_8))
                .collect(Collectors.joining("&"));
    }

    static String find(String text, String regex) {
        Matcher m = Pattern.compile(regex).matcher(text);
        assertThat(m.find()).as("pattern %s in %s", regex, text).isTrue();
        return m.group(1);
    }

    static String b64(String s) {
        return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }
}
