package demo.legacy;

import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.util.UUID;
import java.util.stream.IntStream;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.KeyUse;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.SecurityContext;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.factory.PasswordEncoderFactories;
import org.springframework.security.oauth2.server.authorization.InMemoryOAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2Authorization;
import org.springframework.security.oauth2.server.authorization.OAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2TokenType;
import org.springframework.security.oauth2.server.authorization.token.JwtEncodingContext;
import org.springframework.security.oauth2.server.authorization.token.OAuth2TokenCustomizer;
import org.springframework.security.provisioning.InMemoryUserDetailsManager;

/**
 * Stand-in for the legacy Spring auth server. Spring Boot auto-configures the authorization server (client from
 * application.yaml, login form); the signing key is ours (see {@link #signingKey()}). No fixed issuer: it follows the request host, so one
 * instance serves legacy-net1 and legacy-net2 with an issuer each.
 */
@SpringBootApplication
public class LegacyIdpApplication {

    public static void main(String[] args) {
        SpringApplication.run(LegacyIdpApplication.class, args);
    }

    /**
     * Spring's in-memory store is not safe under concurrent load: findByToken iterates a synchronizedMap-wrapped
     * LinkedHashMap without holding its lock while authorize requests put into it. Under k6 that threw
     * ConcurrentModificationException on /oauth2/token and Keycloak's broker answered 502 (2026-11-02).
     * ponytail: one lock around everything; a test IdP at a few logins/s. JDBC store if it ever has to scale.
     */
    @Bean
    OAuth2AuthorizationService authorizationService() {
        return new SerializedAuthorizationService(new InMemoryOAuth2AuthorizationService());
    }

    record SerializedAuthorizationService(OAuth2AuthorizationService d) implements OAuth2AuthorizationService {
        @Override public synchronized void save(OAuth2Authorization a) { d.save(a); }
        @Override public synchronized void remove(OAuth2Authorization a) { d.remove(a); }
        @Override public synchronized OAuth2Authorization findById(String id) { return d.findById(id); }
        @Override public synchronized OAuth2Authorization findByToken(String t, OAuth2TokenType type) { return d.findByToken(t, type); }
    }

    /**
     * Signing key whose JWK says {@code use: sig} and {@code alg: RS256}. Spring's generated key has neither, and
     * Keycloak 25 ignores JWKS keys without {@code use} (OIDCIdentityProviderPublicKeyLoader -> JWKSUtils), so it
     * could verify no ID token from this IdP: every brokered login on 25 failed with 502 (build #16, major case);
     * 26 accepts a missing {@code use}. A real IdP brokered by Keycloak 25 must publish it.
     * ponytail: a fresh key per start, like Spring's default; keep one in a Secret if restarts must not change it.
     */
    @Bean
    JWKSource<SecurityContext> signingKey() throws Exception {
        KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
        gen.initialize(2048);
        var pair = gen.generateKeyPair();
        RSAKey key = new RSAKey.Builder((RSAPublicKey) pair.getPublic()).privateKey((RSAPrivateKey) pair.getPrivate())
                .keyUse(KeyUse.SIGNATURE).algorithm(JWSAlgorithm.RS256).keyID(UUID.randomUUID().toString()).build();
        return new ImmutableJWKSet<>(new JWKSet(key));
    }

    /** user0001..userNNNN sharing one password, hashed once (thousands of bcrypt hashes would take minutes). */
    @Bean
    UserDetailsService users(@Value("${legacy.users}") int count, @Value("${legacy.user-password}") String password) {
        String hash = PasswordEncoderFactories.createDelegatingPasswordEncoder().encode(password);
        return new InMemoryUserDetailsManager(IntStream.rangeClosed(1, count)
                .mapToObj(i -> (UserDetails) User.withUsername(username(i)).password(hash).roles("USER").build())
                .toList());
    }

    /** Claims Keycloak maps: sub = username (default), plus preferred_username, email and tenant. */
    @Bean
    OAuth2TokenCustomizer<JwtEncodingContext> legacyClaims() {
        return ctx -> {
            String name = ctx.getPrincipal().getName();
            ctx.getClaims().claim("preferred_username", name)
                    .claim("email", name + "@legacy.example")
                    .claim("email_verified", true)
                    .claim("tenant", tenant(name));
        };
    }

    static String username(int i) {
        return "user%04d".formatted(i);
    }

    /** user0042 -> t2 */
    static String tenant(String username) {
        return "t" + Integer.parseInt(username.substring(4)) % 10;
    }
}
