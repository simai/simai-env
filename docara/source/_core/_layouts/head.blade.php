<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="x-ua-compatible" content="ie=edge">
    <meta name="description" content="{{ $page->description ?? $page->siteDescription }}">

    <meta property="og:site_name" content="{{ $page->siteName }}"/>
    <meta property="og:title" content="{{ $page->title ?  $page->title . ' | ' : '' }}{{ $page->siteName }}"/>
    <meta property="og:description" content="{{ $page->description ?? $page->siteDescription }}"/>
    <meta property="og:url" content="{{ $page->getUrl() }}"/>
    <meta property="og:image" content="{{mix('/img/logo.svg', 'assets/build')}}"/>
    <meta property="og:type" content="website"/>
    <meta name="turbo-refresh-method" content="morph">
    <meta name="twitter:image:alt" content="{{ $page->siteName }}">
    <meta name="twitter:card" content="summary_large_image">

    @if ($page->docsearchApiKey && $page->docsearchIndexName)
        <meta name="generator" content="tighten_jigsaw_doc">
    @endif

    <title>{{ $page->siteName }}{{ $page->title ? ' | ' . $page->title : '' }}</title>

    <link rel="home" href="{{ $page->baseUrl }}">
    <link rel="icon" href="/favicon.ico">

    @stack('meta')

    @if ($page->turbo)
        <script src="{{ mix('js/turbo.js', 'assets/build') }}"></script>
    @endif

    @include('_core._layouts.core')
    @php
    $jsTranslation = $page->getJsTranslations();
    @endphp

    @if ($jsTranslation)
        <script>
        window.sfJsLang = {!! json_encode($jsTranslation, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) !!};
        </script>
    @endif
    <link rel="stylesheet" href="{{ mix('css/main.css', 'assets/build') }}">
    <script>
        window.getCookie = function (name) {
            const value = `; ${document.cookie}`;
            const parts = value.split(`; ${name}=`);
            if (parts.length === 2) return parts.pop().split(';').shift();
        }
    </script>
    <script data-turbo-permanent src="{{ mix('js/main.js', 'assets/build') }}"></script>
</head>
