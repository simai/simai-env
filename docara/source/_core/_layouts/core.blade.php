@php
    $hasSha = $page->sha ?? 'latest';
    $locale = $page->locale();
    $distPath = "https://cdn.jsdelivr.net/gh/simai/ui@{$hasSha}/distr/"
@endphp
<link rel="preconnect" href="https://cdn.jsdelivr.net" crossorigin>
<script>

    window.SF_BOOT_CONFIG = {
        icons: {
            accumulate: true,
        },
    };
    window.sfPath = "{{$distPath}}";
    window.currentLocale = `{{$locale}}`
</script>
<script src="{{'https://cdn.jsdelivr.net/gh/simai/ui@'. $hasSha . '/distr/core/js/core.js'}}"></script>
<link rel="preload" as="style"  href="{{'https://cdn.jsdelivr.net/gh/simai/ui@'. $hasSha . '/distr/core/css/core.css'}}">
<link rel="stylesheet" href="{{'https://cdn.jsdelivr.net/gh/simai/ui@'. $hasSha . '/distr/core/css/core.css'}}"/>
