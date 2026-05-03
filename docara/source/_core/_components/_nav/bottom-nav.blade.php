@php
    $navigation = $page->getNavItems();
    $ordered = [];
    foreach (['prev', 'next'] as $k) {
        if (isset($navigation[$k])) {
            $ordered[$k] = $navigation[$k];
        }
    }
@endphp

<section>
    <div class="bottom--navigation flex flex-col md:flex-row p-top-c4 gap-1 m-top-auto">
        <div class="bottom--navigation-items w-full flex gap-1">
            @foreach($ordered as $key => $item)
                @php
                    $prev = $key === 'prev';
                    $text =  $page->translate($prev ? 'previous' : 'next');
                @endphp
                <button type="button" onclick="window.location.href='{{$item['path']}}'" class="sf-button flex sf-button--size-1 sf-button--on-surface sf-button--link items-cross-end bottom--navigation-item_{{$key}} text-start {{ $prev ? 'm-inline-end-auto' : 'm-inline-start-auto text-end' }}">
                    @if($prev)
                        <i class="sf-icon">chevron_left</i>
                    @endif
                    <div class="sf-button-text-container sf-button-text sf-text-1">
                        <div class="flex bottom--navigation_text flex-col sf-text-1 gap-1/4">
                            <div class="sf-text-1/3">{{$text}}</div>
                            <div class="sf-text-1 m-0">{{$item['label']}}</div>
                        </div>
                    </div>
                    @if(!$prev)
                        <i class="sf-icon">chevron_right</i>
                    @endif
                </button>
            @endforeach
        </div>
    </div>
</section>
