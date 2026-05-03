@php
    $brand = $page->brand ?? [];
    $brandTitle = $brand['title'] ?? $page->siteName ?? 'Documentation';
    $brandLogoSvg = $brand['logoSvg'] ?? null;
    $brandHomeUrl = rtrim((string) ($page->baseUrl ?? '/'), '/') ?: '/';
@endphp

<a href="{{ $brandHomeUrl }}" title="{{ $page->siteName }} home" class="logo sf-logo inline-flex items-center">
    <span class="sf-logo-mark" aria-hidden="true">
        @if($brandLogoSvg)
            {!! $brandLogoSvg !!}
        @else
            <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none" viewBox="0 0 32 32">
                <path fill="#e81123" d="M0 3.2C0 1.433 1.428 0 3.19 0h25.514a3.195 3.195 0 0 1 3.189 3.2v25.6c0 1.767-1.428 3.2-3.19 3.2H3.19A3.195 3.195 0 0 1 0 28.8z"/>
                <path fill="#f7f7f7" fill-rule="evenodd" d="m4.629 16 8.541-8.602 2.776 2.796-5.766 5.807 5.765 5.807-2.775 2.795z" clip-rule="evenodd"/>
                <path fill="#f7f7f7" fill-rule="evenodd" d="M27.262 16 18.72 7.399l-2.776 2.796 5.766 5.807-5.765 5.807 2.775 2.795z" clip-rule="evenodd"/>
            </svg>
        @endif
    </span>
    <span class="sf-logo-title">{{ $brandTitle }}</span>
</a>
