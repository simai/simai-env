<aside id="main_menu" class="sf-nav-menu w-full sf-nav-menu--left flex flex-col content-main-between p-0 lg:p-y-3 gap-2 sticky overflow-auto">
    @includeWhen($section['menu']['enabled'], '_core._components._nav.left-menu')
    @includeWhen($section['tools']['enabled'], '_core._components.aside-tools-left')
</aside>
