@php
    $arLocales = $page->locales->toArray();
    $currentLocale =  $page->locale();
@endphp

<div class="sf-language-switch sf-language-switch--container flex">
    <button  onclick="langOpen(this)" class=" sf-icon-button sf-icon-button--icon radius-default sf-icon-button--size-1 sf-icon-button--link sf-icon-button--on-surface sf-button--nav-switch sf-language-switch--button"
            id="lang_switch">
        <i class="sf-icon">language</i>
    </button>
    <div class="sf-language-switch--language-panel absolute radius-default bg-surface-overlay hidden" id="language_panel">
        <ul class="sf-language-switch--language-list flex flex-col w-full p-1/3">
            @foreach($arLocales as $key => $locale)
                    <li class="sf-language-switch--language-item">
                        <button data-locale="{{$key}}" onclick="langSwitch(this)" class="sf-button w-full flex items-center content-main-between sf-button--size-1/2 sf-button--on-surface sf-button--link {{$key === $currentLocale ? 'active' : ''}}" type="button">
                            <span class="sf-button-text sf-button-text-container">{{$locale}}</span>
                            <i class="sf-icon {{$key === $currentLocale ? '' : 'hidden'}}">check</i>
                        </button>
                    </li>
            @endforeach
        </ul>
    </div>

</div>
