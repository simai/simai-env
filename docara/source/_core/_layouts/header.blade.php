<header class="w-full flex z-8 sticky border-bottom-1 border-outline-variant bg-surface-0 box-border" role="banner">
    <div class="header--wrap flex flex-1 items-cross-center container gap-1 px-b6 m-auto">
        @includeWhen($section['logo']['enabled'], '_core._components.header.logo')
        @if($page->category)
            @includeWhen($section['topMenu']['enabled'], '_core._components.header.top-menu')
        @endif
        <div class="flex flex-1 content-main-end items-center text-end md:pl-10 gap-x-1">
            @includeWhen($section['search']['enabled'], '_core._components.header.search')
            @includeWhen($section['toolbar']['enabled'], '_core._components.header.tools',['section' => layout_section($page, 'toolbar.items')])
        </div>
    </div>
</header>
