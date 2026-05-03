<!DOCTYPE html>
@php
    $locale = $page->locale();
    $page->configurator->setLocale($locale);
@endphp


<html lang="{{$locale}}">

@include('_core._layouts.head')

<body class="flex flex-col justify-between min-h-screen leading-normal max-container-6">

@includeWhen(layout_enabled($page, 'header'), '_core._layouts.header', ['section' => layout_section($page, 'header.blocks')])

@include('_core._layouts.main')

@includeWhen(layout_enabled($page, 'footer'), '_core._layouts.footer')

@includeWhen(layout_enabled($page, 'floating'), '_core._components.floating')

@stack('scripts')

</body>
</html>
