<#-- Copy of 26.7.5 base/login/error.ftl + version marker. -->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=false; section>
    <#if section = "header">
        ${kcSanitize(msg("errorTitle"))?no_esc}
    <#elseif section = "form">
        <div class="demo-theme-version" data-theme-version="v${properties.themeVersion!}"></div>
        <div id="kc-error-message">
            <p class="instruction">${kcSanitize(message.summary)?no_esc}</p>
            <#if traceId??>
                <p class="instruction" id="traceId">${msg("traceIdSupportMessage", traceId)}</p>
            </#if>
            <#if skipLink??>
            <#else>
                <#if client?? && client.baseUrl?has_content>
                    <p><a id="backToApplication" href="${client.baseUrl}">${msg("backToApplication")}</a></p>
                </#if>
            </#if>
        </div>
    </#if>
</@layout.registrationLayout>