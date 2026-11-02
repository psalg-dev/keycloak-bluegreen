package demo.kc;

import org.keycloak.Config;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

public class ReplayEventListenerFactory implements EventListenerProviderFactory {
    @Override
    public String getId() {
        return "demo-replay";
    }

    @Override
    public EventListenerProvider create(KeycloakSession session) {
        return new ReplayEventListener(session, System.out);
    }

    @Override
    public void init(Config.Scope config) {
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
    }

    @Override
    public void close() {
    }
}
