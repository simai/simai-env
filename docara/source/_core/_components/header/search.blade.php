<div id="search_doc" class="search--wrap flex content-main-end ml-auto w-0 sm:w-full text-end ">
    <script>
        window.sfSearchNotFound = '{{$page->translate('notFound')}}'
    </script>
    <div class="sf-input-container sf-input-search-container grow-none relative">
        <label id="input_search" class="sf-input sf-input--size-1 sf-input--bordered flex flex-col">
        <span class="sf-input-field items-cross-center transition flex">
        <i class="sf-icon">search</i>
               <input name="search" type="text" class="sf-input-main sf-input-text"
                      placeholder="{{$page->translate('search')}}">
        <div class="sf-input-right">
            <button id="search_close" type="button"
                    class="sf-icon-button hidden sf-icon-button--close sf-icon-button--on-surface sf-icon-button--link border-0 sf-icon-button--size-1/3">
            <span class="sf-close sf-close--size-1/3 flex content-main-center items-cross-center"
                  aria-label="Close">
              <span class="sf-close-icon"></span>
            </span>
          </button>
        </div>
      </span>
        </label>
        <div id="search_results" class="docsearch-input__holder hidden absolute inline-end-0 p-b6 radius-1">
            <div class="docsearch-input__main flex flex-col overflow-auto gap-1/4"></div>
        </div>
    </div>
</div>


