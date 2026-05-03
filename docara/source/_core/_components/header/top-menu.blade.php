@php
    $locale = $page->locale();
    $topMenu = $page->configurator->getTopMenu($locale);
@endphp

<div class="dc-menu-container items-cross-center flex relative overflow-hidden m-inline-start-0 m-bottom-c2 md:m-inline-start-c8 md:m-bottom-0 flex-1">
    <button onclick="menuScroll(this, false)" class="dc-menu-scroll left absolute hidden inline-start-0 top-1/2 translate-y-half" type="button">
        <i class="sf-icon">chevron_left</i>
    </button>
    <div id="top_menu" class="dc-menu truncate inline-flex gap-1">
        @foreach($topMenu as $key => $item)
        <div class="dc-menu-item">
            <a class="color-on-surface weight-5" href="{{$item['path']}}">{{$item['title']}}</a>
        </div>
        @endforeach
    </div>
    <button onclick="menuScroll(this, true)" class="dc-menu-scroll right absolute hidden inline-end-0 top-1/2 translate-y-half" type="button">
        <i class="sf-icon">chevron_right</i>
    </button>
</div>
