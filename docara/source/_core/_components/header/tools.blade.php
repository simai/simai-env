<div class="header--right flex gap-1/4 relative">
    <button class="sf-icon-button radius-default sf-button-search sf-icon-button--size-1 sf-icon-button--link sf-icon-button--on-surface side-menu-instrument flex sm:hidden">
        <i class="sf-icon">search</i>
    </button>
    <button id="read_mode" onclick="applyReadMode(this)"
            class=" sf-icon-button sf-icon-button--icon radius-default sf-button-readMode sf-icon-button--size-1 sf-icon-button--link sf-icon-button--on-surface side-menu-instrument">
        <i class="sf-icon">fullscreen</i>
    </button>
    @includeWhen(count($page->locales ?? []) > 1,'_core._components.header.language')
    @include('_core._components.header.settings')
    @include('_core._components.header.more')
    <button onclick="toggleMobileMenu(this)"
            class=" sf-icon-button radius-default sf-button-nav sf-icon-button--size-1 sf-icon-button--on-surface sf-icon-button--link sf-button--nav-switch">
        <i class="sf-icon">menu</i>
    </button>
</div>
