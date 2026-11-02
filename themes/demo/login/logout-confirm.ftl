<#-- Copy of 26.7.5 base/login/logout-confirm.ftl + version marker. -->
<#import "template.ftl" as layout>
<@layout.registrationLayout; section>
    <#if section = "header">
        ${msg("logoutConfirmTitle")}
    <#elseif section = "form">
        <div class="demo-theme-version" data-theme-version="v${properties.themeVersion!}"></div>
        <div id="kc-logout-confirm" class="content-area">
            <p class="instruction">${msg("logoutConfirmHeader")}</p>

            <form class="form-actions" action="${url.logoutConfirmAction}" onsubmit="confirmLogout.disabled = true; return true;" method="POST">
                <input type="hidden" name="session_code" value="${logoutConfirm.code}">
                <div class="${properties.kcFormGroupClass!}">
                    <div id="kc-form-options">
                        <div class="${properties.kcFormOptionsWrapperClass!}">
                        </div>
                    </div>

                    <div id="kc-form-buttons" class="${properties.kcFormGroupClass!}">
                        <input tabindex="4"
                               class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!} ${properties.kcButtonLargeClass!}"
                               name="confirmLogout" id="kc-logout" type="submit" value="${msg("doLogout")}"/>
                    </div>

                </div>
            </form>

            <div id="kc-info-message">
                <#if logoutConfirm.skipLink>
                <#else>
                    <#if (client.baseUrl)?has_content>
                        <p><a href="${client.baseUrl}">${msg("backToApplication")}</a></p>
                    </#if>
                </#if>
            </div>

            <div class="clearfix"></div>
        </div>
    </#if>
</@layout.registrationLayout>
