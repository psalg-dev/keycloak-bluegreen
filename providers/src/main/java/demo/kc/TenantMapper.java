package demo.kc;

import org.keycloak.models.UserSessionModel;

/** User attribute `tenant` -> claim `tenant`. */
public class TenantMapper extends ClaimMapper {
    public TenantMapper() {
        super("tenant");
    }

    @Override
    String value(UserSessionModel us) {
        return us.getUser().getFirstAttribute("tenant");
    }

    @Override
    public String getId() {
        return "demo-tenant-mapper";
    }

    @Override
    public String getDisplayType() {
        return "Demo tenant";
    }

    @Override
    public String getHelpText() {
        return "User attribute 'tenant' -> claim 'tenant' (access, id, userinfo).";
    }
}
