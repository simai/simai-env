export class Search {
    constructor(params) {
        const header = document.querySelector('header');
        if (!header) {
            return null;
        }
        this.value = '';
        this._cache = new Map();
        this._abortCtrl = null;
        this.mode = 'fuse';
        this.debounceMs = 500;
        this.results = null;
        this.bitrixSearch = null;
        this.minChars = 2;
        this._debouncedDoSearch = this._debounce(this._doSearch.bind(this), this.debounceMs);
        this.initParams(params);
        this.init();
    }

    initParams(params) {
        if (!params) return;
        Object.keys(params).forEach(key => {
            this[key] = params[key];
        });
    }

    init() {
        this.wrap = document.getElementById('search_doc');
        this.searchButton = document.querySelector('.sf-button-search');
        this.inputContainer = this.wrap.querySelector('.sf-input-search-container');
        this.menu = document.querySelector(".sf-menu-container");
        this.input = document.getElementById('input_search').querySelector('input');
        this.resultsWrap = document.getElementById('search_results');
        this.resultsContainer = this.resultsWrap.querySelector('.docsearch-input__main');
        this.logo = document.querySelector('a.logo');
        this.headerRight = document.querySelector('.header--right');
        this.close = this.wrap.querySelector('#search_close');
        [this.searchButton, this.input].forEach((item) => {
            item.addEventListener('click', () => {
                this.openSearch();
            });
        });
        this.close.addEventListener('click', () => {
            this.value = '';
            this.input.value = '';
            this.clearResults();
            this.closeState(this.value !== '');

        });
        this.initDoc();

    }

    setMode(mode) {
        this.mode = mode;
        this.clearResults();
        if (this.input?.value?.trim().length >= this.minChars) {
            this._debouncedDoSearch(this.input.value.trim(), 'focus');
        } else {
            this._debouncedDoSearch.cancel?.();
        }
    }

    async _doSearch(query, event) {
        if (this._abortCtrl) this._abortCtrl.abort();
        this._abortCtrl = new AbortController();

        const cacheKey = `${this.mode}:${query}`;
        if (this._cache.has(cacheKey)) {
            const cached = this._cache.get(cacheKey);
            this._renderByEvent(cached, event);
            return;
        }

        let results = [];
        try {
            if (this.mode === 'fuse') {
                results = this._searchFuse(query);
            } else if (this.mode === 'bitrix') {
                results = await this._searchBitrix(query, this._abortCtrl.signal);
                results = this._normalizeResults(results);
            } else if (this.mode === 'hybrid') {
                const [r1, r2] = await Promise.allSettled([
                    Promise.resolve(this._searchFuse(query)),
                    this._searchBitrix(query, this._abortCtrl.signal)
                ]);
                results = [
                    ...(r1.status === 'fulfilled' ? r1.value : []),
                    ...(r2.status === 'fulfilled' ? r2.value : []),
                ];
                return results;
            }

            this._cache.set(cacheKey, results);
            this._renderByEvent(results, event);
        } catch (e) {
            if (e.name === 'AbortError') return; // нормально — отменили
            console.warn('Search error:', e);
            this.renderResults([]);
        }
    }

    _normalizeResults(results) {
        if (!results) return null;
        const data = [];
        for (const key in results.items) {
            const {snippet, title, url} = results.items[key];
            const replaced = snippet.replace(/<\/?b>/g, tag => tag === '<b>' ? '<mark>' : '</mark>');
            data.push({
                item: {title: title, content: replaced, url: url},
            });
        }
        return data;
    }

    _renderByEvent(results, event) {
        if (event === 'focus') {
            setTimeout(() => this.renderResults(results), 100);
        } else {
            this.renderResults(results);
            this.closeState(this.value !== '');
        }
    }

    _debounce(fn, wait) {
        let t;

        function debounced(...args) {
            clearTimeout(t);
            t = setTimeout(() => fn.apply(this, args), wait);
        }

        debounced.cancel = () => clearTimeout(t);
        return debounced;
    }

    _searchFuse(query) {
        if (!this.fuse) return [];
        const res = this.fuse.search(query);

        return res.map(r => ({
            item: {title: r.item.title, content: r.item.content, url: r.item.url},
            matches: (r.matches || []).map(m => ({
                key: m.key, value: m.value, indices: m.indices
            }))
        }));
    }

    async _searchBitrix(query, signal) {
        if (!this.bitrixSearch) return [];
        return await this.bitrixSearch(query, {signal});
    }

    clearResults() {
        this.resultsContainer.innerHTML = '';
        this.resultsWrap.classList.add('hidden');
        this.results = null;
    }

    initDoc() {
        if (!this.input) return;

        ['input', 'focus'].forEach(event => {
            this.input.addEventListener(event, (e) => {
                    const value = e.target.value.trim();
                    this.openSearch();
                    if (this.results) {
                        if (event === 'focus') {
                            setTimeout(() => {
                                this.resultsWrap.classList.remove('hidden');
                            }, 290);

                        } else {
                            this.resultsWrap.classList.remove('hidden');
                        }
                    }
                    if (this.value === value) return;

                    if (value.length >= this.minChars) {
                        this.value = value;
                        this._debouncedDoSearch(value, event);
                    } else {
                        if (!value.length) this.resultsWrap.classList.add('hidden');
                    }
                }
            )
            ;
        });

        document.addEventListener('click', (event) => {
            if (event.target !== this.wrap && event.target !== this.searchButton &&
                !this.searchButton.contains(event.target) && !this.wrap.contains(event.target)) {
                this.closeSearch();
                this._debouncedDoSearch.cancel?.();
            }
        });
    }

    highlightMatch(text, indices) {
        if (!indices || !indices.length) return text;

        let result = '';
        let lastIndex = 0;

        for (const [start, end] of indices) {
            result += text.slice(lastIndex, start);
            result += '<mark>' + text.slice(start, end + 1) + '</mark>';
            lastIndex = end + 1;
        }

        result += text.slice(lastIndex);
        return result;
    }

    getExcerptWithHighlightSmart(text, indices, context = 60) {
        if (!indices?.length) return text;
        indices.sort((a, b) => (a[1] - a[0]) - (b[1] - b[0]));
        const [start, end] = indices[indices.length - 1];

        const firstNewlineIndex = text.indexOf('\n');
        const isInFirstLine = firstNewlineIndex === -1 || start < firstNewlineIndex;


        if (isInFirstLine && (firstNewlineIndex === -1 || firstNewlineIndex <= context * 2)) {
            const lineEnd = firstNewlineIndex === -1 ? text.length : firstNewlineIndex;
            const before = text.slice(0, start);
            const match = text.slice(start, end + 1);
            const after = text.slice(end + 1, lineEnd);
            return `${before}<mark>${match}</mark>${after}`;
        }

        const excerptStart = Math.max(start - context, 0);
        const excerptEnd = Math.min(end + context + 1, text.length);
        const before = text.slice(excerptStart, start);
        const match = text.slice(start, end + 1);
        const after = text.slice(end + 1, excerptEnd);

        return `${excerptStart > 0 ? '…' : ''}${before}<mark>${match}</mark>${after}${excerptEnd < text.length ? '…' : ''}`;
    }

    renderResults(results, containerId = 'search_results') {
        this.resultsContainer.innerHTML = '';

        if (!results.length) {
            const text = window.sfSearchNotFound !== 'undefined' ? window.sfSearchNotFound : 'Ничего не найдено';
            this.resultsContainer.innerHTML = `<p class="search--result-content text-left">${text}</p>`;
            this.resultsWrap.classList.remove('hidden');
            return;
        }
        this.results = results;
        results.forEach(result => {
            const {item, matches} = result;

            let highlightedTitle = item.title;
            let highlightedContent = item.content?.slice(0, 200) || '';

            matches && matches.forEach(match => {
                if (match.key === 'title') {
                    highlightedTitle = this.highlightMatch(match.value, match.indices);
                } else if (match.key === 'content') {
                    highlightedContent = this.getExcerptWithHighlightSmart(item.content, match.indices);
                }
            });

            const block = document.createElement('div');
            block.className = 'search--result text-left p-a8 radius-1';
            block.innerHTML = `
      <a class="flex flex-col gap-1/4" href="${item.url}">
        <div class="search--result-title sf-text-1 weight-7">${highlightedTitle}</div>
              <p class="search--result-content sf-text-1 m-0">${highlightedContent}</p>
      </a>
    `;

            this.resultsContainer.appendChild(block);
            this.resultsWrap.classList.remove('hidden');
        });
    }

    closeState(state) {
        if (!state) {
            this.close.classList.add('hidden');
        } else {
            this.close.classList.remove('hidden');
        }
    }

    searchGetter() {
        return this.input;
    }

    menuGetter() {
        return this.menu;
    }

    closeSearch() {
        this.resultsWrap.classList.add('hidden');
        this.inputContainer.classList.add('grow-none');
        this.inputContainer.classList.remove('grow');
        this.wrap.classList.remove('open');
        if (window.innerWidth < 520) {
            this.wrap.classList.remove('visible');
        }
        if (window.innerWidth < 768) {
            this.logo.classList.remove('hidden');
            this.headerRight.classList.remove('hidden');
        } else {
            this.menu?.classList.remove('hidden');
        }

    }

    openSearch() {
        this.inputContainer.classList.remove('grow-none');
        this.inputContainer.classList.add('grow');
        this.wrap.classList.add('open');
        if (window.innerWidth < 520) {
            this.wrap.classList.add('visible');
        }
        if (window.innerWidth < 768) {
            this.logo.classList.add('hidden');
            this.headerRight.classList.add('hidden');
        } else {
            this.menu?.classList.add('hidden');
        }
    }

    searchDocumentClick() {
        if (!this.input.contains(event.target)) {
        }
    }
}
