package demo.legacy;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.server.authorization.InMemoryOAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2Authorization;
import org.springframework.security.oauth2.server.authorization.OAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClient;

/** Authorize requests save while token requests look up, concurrently: the k6 load pattern that broke the IdP. */
class AuthorizationServiceConcurrencyTest {

    static final RegisteredClient CLIENT = RegisteredClient.withId("c").clientId("c")
            .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE).redirectUri("https://app/cb").build();

    @Test
    void serializedServiceSurvivesConcurrentSaveAndLookup() throws Exception {
        assertThat(hammer(new LegacyIdpApplication.SerializedAuthorizationService(new InMemoryOAuth2AuthorizationService()), 2))
                .isNull();
    }

    /** Negative control: proves this test can see the bug (Spring's raw in-memory store throws under the same load). */
    @Test
    void rawInMemoryServiceThrowsUnderTheSameLoad() throws Exception {
        assertThat(hammer(new InMemoryOAuth2AuthorizationService(), 10)).isInstanceOf(java.util.ConcurrentModificationException.class);
    }

    /** 4 writers save authorizations that have no access token yet (Spring keeps those in its non-concurrent map),
     *  4 readers run findByToken over them, for up to N s (stops at the first exception). Returns the first exception, or null. */
    static Throwable hammer(OAuth2AuthorizationService service, int seconds) throws Exception {
        AtomicReference<Throwable> failure = new AtomicReference<>();
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds);
        ExecutorService pool = Executors.newFixedThreadPool(8);
        for (int t = 0; t < 8; t++) {
            boolean writer = t % 2 == 0;
            pool.submit(() -> {
                while (System.nanoTime() < end && failure.get() == null) {
                    try {
                        if (writer) {
                            service.save(OAuth2Authorization.withRegisteredClient(CLIENT).id(UUID.randomUUID().toString())
                                    .principalName("p").authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                                    .attribute("state", UUID.randomUUID().toString()).build());
                        } else {
                            service.findByToken(UUID.randomUUID().toString(), null);
                        }
                    } catch (Throwable e) {
                        failure.compareAndSet(null, e);
                    }
                }
            });
        }
        pool.shutdown();
        pool.awaitTermination(seconds + 10, TimeUnit.SECONDS);
        return failure.get();
    }
}
