---
extends: _core._layouts.documentation
section: content
title: Главная
description: Добро пожаловать
---
@php
$locales = $page->configurator->locales;
$index = $page->configurator->indexPage;
@endphp

<script>
(function () {
    function getCookie(name) {
        const value = `; ${document.cookie}`;
        const parts = value.split(`; ${name}=`);
        if (parts.length === 2) return parts.pop().split(';').shift();
    }

    const supportedLocales = @json($locales);
    const fallbackLocale = supportedLocales.includes('en') ? 'en' : supportedLocales[0];
    const cookieLocale = getCookie('locale');

    const locale = cookieLocale && supportedLocales.includes(cookieLocale)
        ? cookieLocale
        : fallbackLocale;
    const redirectTo = `${locale}/{{$index}}`;

    window.location.replace(redirectTo);
})();
</script>

<p>Redirecting to your language...</p>
