package demo.testresource;

import java.io.IOException;
import java.net.http.HttpClient;
import java.time.Duration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.ssl.SslBundles;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.core.Ordered;
import org.springframework.http.HttpHeaders;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.ProviderManager;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationProvider;
import org.springframework.security.oauth2.server.resource.authentication.JwtIssuerAuthenticationManagerResolver;
import org.springframework.security.oauth2.server.resource.web.DefaultBearerTokenResolver;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.web.client.RestTemplate;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Resource server for the cutover measurements (docs/test-apps-contract.md). Trusts exactly the two kc-netN issuers.
 * Keycloak endpoints are derived from the issuer, not discovered: startup does not depend on Keycloak.
 */
@SpringBootApplication
public class TestResourceApplication {

    static final List<String> NETS = List.of("net1", "net2");
    /** Request attribute: why a request failed, for the `request` log line. */
    static final String ERROR = "demo.error";

    public static void main(String[] args) {
        SpringApplication.run(TestResourceApplication.class, args);
    }

    static String issuer(String template, String net) {
        return template.replace("{net}", net);
    }

    /**
     * HTTP to Keycloak (JWKS, introspection): trusts the demo CA (SSL bundle demo-ca), and has timeouts, so a hung
     * Keycloak shows up as a measured introspection "timeout" instead of a hung request.
     */
    static RestTemplate keycloakClient(SslBundles bundles) {
        JdkClientHttpRequestFactory http = new JdkClientHttpRequestFactory(HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(2))
                .sslContext(bundles.getBundle("demo-ca").createSslContext())
                .build());
        http.setReadTimeout(Duration.ofSeconds(5));
        return new RestTemplate(http);
    }

    /** /api/jwt: local JWT validation, the token's issuer picks the JWKS. Unknown issuer = 401. */
    @Bean
    SecurityFilterChain security(HttpSecurity http, @Value("${demo.issuer}") String issuerTemplate, SslBundles bundles) {
        RestTemplate jwks = keycloakClient(bundles);
        Map<String, AuthenticationManager> byIssuer = new HashMap<>();
        for (String net : NETS) {
            String iss = issuer(issuerTemplate, net);
            NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(iss + "/protocol/openid-connect/certs")
                    .restOperations(jwks).build();
            decoder.setJwtValidator(JwtValidators.createDefaultWithIssuer(iss));
            byIssuer.put(iss, new ProviderManager(new JwtAuthenticationProvider(decoder)));
        }
        DefaultBearerTokenResolver bearer = new DefaultBearerTokenResolver();
        http.authorizeHttpRequests(a -> a.requestMatchers("/api/jwt").authenticated().anyRequest().permitAll())
                .oauth2ResourceServer(o -> o
                        .authenticationManagerResolver(new JwtIssuerAuthenticationManagerResolver(byIssuer::get))
                        // /api/introspect validates in its controller: Spring maps an introspection failure to 500,
                        // the contract wants 503 (failure) vs 401 (inactive).
                        .bearerTokenResolver(r -> "/api/jwt".equals(r.getRequestURI()) ? bearer.resolve(r) : null))
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .csrf(c -> c.disable());
        return http.build();
    }

    /** One `request` line per /api/* call, whatever answered it (Spring Security's 401s included). */
    @Bean
    FilterRegistrationBean<OncePerRequestFilter> requestLog() {
        Pattern description = Pattern.compile("error_description=\"([^\"]*)\""), code = Pattern.compile("error=\"([^\"]*)\"");
        FilterRegistrationBean<OncePerRequestFilter> reg = new FilterRegistrationBean<>(new OncePerRequestFilter() {
            @Override
            protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
                    throws ServletException, IOException {
                long t0 = System.nanoTime();
                String error = null;
                int status = 500;
                try {
                    chain.doFilter(req, res);
                    status = res.getStatus();
                    if (status != 200) { // ours, else Spring Security's WWW-Authenticate (description first: says why)
                        String www = String.valueOf(res.getHeader(HttpHeaders.WWW_AUTHENTICATE));
                        Matcher d = description.matcher(www), c = code.matcher(www);
                        error = req.getAttribute(ERROR) instanceof String e ? e
                                : d.find() ? d.group(1) : c.find() ? c.group(1) : "http_" + status;
                    }
                }
                catch (IOException | ServletException | RuntimeException e) {
                    error = e.getClass().getSimpleName() + ": " + e.getMessage();
                    throw e;
                }
                finally {
                    Map<String, Object> claims = Events.unverifiedClaims(Api.bearer(req));
                    Events.log("request", "path", req.getRequestURI(), "status", status, "latency_ms", Events.ms(t0),
                            "iss", claims.get("iss"), "sub", claims.get("sub"), "error", error);
                }
            }
        });
        reg.addUrlPatterns("/api/*");
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE);
        return reg;
    }
}
