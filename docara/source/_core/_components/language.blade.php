@php
    $arLocales = $page->locales->toArray();
    $currentLocale =  $page->locale();
@endphp

<div class="sf-language-switch sf-language-switch--container flex">
    <button  onclick="langOpen(this)" class=" sf-icon-button radius-default sf-icon-button--size-1 sf-icon-button--link sf-icon-button--on-surface sf-button--nav-switch sf-language-switch--button"
            id="lang_switch">
        <i class="sf-icon">language</i>
    </button>
    <div class="sf-language-switch--language-panel absolute bg-surface-overlay hidden" id="language_panel">
        <ul class="sf-language-switch--language-list flex flex-col w-max">
            @foreach($arLocales as $key => $locale)
                    <li class="sf-language-switch--language-item">
                        <button data-locale="{{$key}}" onclick="langSwitch(this)" class="w-full flex items-center content-main-between {{$key === $currentLocale ? 'active' : ''}}" type="button">{{$locale}}</button>
                    </li>
            @endforeach
        </ul>
    </div>

</div>
