package demo.legacy;

import java.util.stream.IntStream;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.factory.PasswordEncoderFactories;
import org.springframework.security.oauth2.server.authorization.token.JwtEncodingContext;
import org.springframework.security.oauth2.server.authorization.token.OAuth2TokenCustomizer;
import org.springframework.security.provisioning.InMemoryUserDetailsManager;

/**
 * Stand-in for the legacy Spring auth server. Spring Boot auto-configures the authorization server (client from
 * application.yaml, generated signing key, login form). No fixed issuer: it follows the request host, so one
 * instance serves legacy-net1 and legacy-net2 with an issuer each.
 */
@SpringBootApplication
public class LegacyIdpApplication {

    public static void main(String[] args) {
        SpringApplication.run(LegacyIdpApplication.class, args);
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
