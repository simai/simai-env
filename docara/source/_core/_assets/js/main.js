import Fuse from 'fuse.js';
import { Search } from './helpers/Search.js';
import { SizeObserver } from './helpers/ResizeObserver';
import setReadModePosition from './helpers/functions';
import './helpers/SfStickyOffsets';

const locale = window.currentLocale ?? '';

window.toggleNav = (btn) => {
    btn.closest('.sf-nav-menu-element').classList.toggle('active');
};

let _fusePromise;

let fontsReady = false,
    turboEnable = false;

// Prevent visible smooth scroll on first paint.
let initialMenuScrollDone = false;

function getFuseOnce() {
    if (!_fusePromise) _fusePromise = initFuse();
    return _fusePromise;
}

function scrollToActiveMenu() {
    const menu = document.querySelector('.sf-nav-wrap');
    if (!menu) return;
    const activeItem = menu.querySelector('.sf-nav-item.active');
    const activeCategories = Array.from(
        menu.querySelectorAll('.sf-nav-menu-element.active'),
    );

    if (activeItem) {
        scrollIntoMenu(activeItem, menu, { center: true });
    } else if (activeCategories.length) {
        scrollIntoMenu(activeCategories[activeCategories.length - 1], menu, {
            center: false,
        });
    }
}

function scrollIntoMenu(target, menu, { center = false } = {}) {
    const targetLeft = center
        ? target.offsetLeft - (menu.clientWidth - target.offsetWidth) / 2
        : target.offsetLeft;
    const maxLeft = menu.scrollWidth - menu.clientWidth;
    const left = Math.min(Math.max(targetLeft, 0), maxLeft);

    const needsScroll =
        left < menu.scrollLeft ||
        left > menu.scrollLeft + menu.clientWidth - target.offsetWidth;

    if (!needsScroll) return;

    const doScroll = (behavior) => {
        menu.scrollTo({ left, behavior });
        initialMenuScrollDone = true;
    };

    if (!initialMenuScrollDone) {
        // Do it before the first painted frame so пользователь не видит анимацию.
        const originalBehavior = menu.style.scrollBehavior;
        menu.style.scrollBehavior = 'auto';
        requestAnimationFrame(() => {
            doScroll('auto');
            // Restore smooth scrolling after the first frame.
            requestAnimationFrame(() => {
                menu.style.scrollBehavior = originalBehavior || '';
            });
        });
    } else {
        doScroll('smooth');
    }
}

window.initSearch = async function initSearch(params = {}) {
    const mode = params.mode ?? 'fuse';

    const fuse =
        params.fuse ??
        (mode === 'fuse' && typeof Fuse === 'function'
            ? await getFuseOnce()
            : null);

    if (mode === 'fuse' && !fuse) {
        console.warn('Fuse mode selected, but Fuse is unavailable.');
        return null;
    }

    return new Search({
        ...params,
        ...(fuse && { fuse }),
    });
};

async function initFuse() {
    return await fetch(`/search-index_${locale}.json`)
        .then((response) => response.json())
        .then((data) => {
            const options = {
                keys: ['title', 'content', 'headings.text'],
                threshold: 0.0,
                ignoreLocation: true,
                distance: 0,
                minMatchCharLength: 3,
                includeScore: true,
                findAllMatches: true,
                includeMatches: true,
            };
            return new Fuse(data, options);
        })
        .catch((e) => {
            console.error(e);
            return null;
        });
}

window.copyAnchor = function (link) {
    navigator.clipboard.writeText(link.href);
};

function initClicks(navLinks, header) {
    navLinks.forEach((anchor) => {
        anchor.addEventListener('click', function (e) {
            if (window.innerWidth < 768) {
                window.navOpen();
            }
            e.preventDefault();

            const targetId = this.getAttribute('href').substring(1);
            const targetElement = document.getElementById(targetId);

            if (targetElement) {
                const headerHeight = header ? header.offsetHeight : 0;
                const elementPosition =
                    targetElement.getBoundingClientRect().top + window.scrollY;
                const offsetPosition = elementPosition - headerHeight;

                window.scrollTo({
                    top: offsetPosition - 20,
                    behavior: 'smooth',
                });
            }
        });
    });
}

window.toggleMobileMenu = function (button) {
    const mainMenu = document.getElementById('main_menu');
    const icon = button.querySelector('.sf-icon');
    const navMenu = document.getElementById('side_menu');
    if (mainMenu) {
        mainMenu.classList.toggle('active');
        if (mainMenu.classList.contains('active')) {
            document.body.classList.add('overflow-hidden');
        } else {
            document.body.classList.remove('overflow-hidden');
        }
        icon.textContent = mainMenu.classList.contains('active') ? 'close' : 'menu';
    }
    if (navMenu) {
        navMenu.classList.remove('active');
    }
};

window.toggleFloat = function (button) {
    const wrap = button.parentNode;
    wrap.classList.toggle('active');
};

window.addEventListener('Switch:render', (event) => {
    const { detail } = event;
    const { html } = detail;
    if (html) {
        const input = html.querySelector('input');
        switch (html.id) {
            case 'theme_switch':
                input.checked = SF.Loader.theme === 'dark';
                input.addEventListener('change', (event) => {
                    SF.Loader.changeTheme();
                });
                break;
            case 'widescreen_switch':
                input.checked = getInitialState('expanded');
                input.addEventListener('change', () => {
                    toggleResize();
                });
                break;
        }
        if (typeof detail.checked === 'function') {
            detail.checked();
        }
    }
});

window.setIssue = function (githubUrl) {
    const selection = window.getSelection();
    const text = selection ? selection.toString().trim() : '';

    let title, body;

    if (text.length > 0) {
        title = 'Issue: ' + text.slice(0, 60);
        body = '**Selected text:**\n\n' + text;
    } else {
        title = 'New Issue';
        body = 'Please describe the issue here.';
    }

    const issueUrl =
        `${githubUrl}issues/new?` +
        'title=' + encodeURIComponent(title) +
        '&body=' + encodeURIComponent(body);

    window.open(issueUrl, '_blank');
};

function toggleLinksWidth() {
    const navLinks = document.querySelectorAll('.sf-side-menu-list-item a');
    const wrap = document.getElementById('side_menu_list');
    lockInlineWidth(navLinks, wrap);
}

function initNavLinks() {
    const headers = document.querySelectorAll(
        'h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]',
    );
    const navLinks = document.querySelectorAll('.sf-side-menu-list-item a');
    const header = document.querySelector('header');
    const visibleIds = new Set();
    const wrap = document.getElementById('side_menu_list');
    const headerHeight = header ? header.offsetHeight : 0;
    navLinks.forEach((link) => navClick(link, headerHeight));
    if (navLinks[0]) {
        const familyRaw = window.getComputedStyle(navLinks[0]).fontFamily;

        const mainFont = familyRaw
            .split(',')[0]
            .trim()
            .replace(/^['"]|['"]$/g, '');
        if(turboEnable && fontsReady) {
            lockInlineWidth(navLinks, wrap);
        }
        document.fonts.addEventListener('loadingdone', (event) => {
            fontsReady = true;
            const hasInter = event.fontfaces.some((f) => f.family === mainFont);
            if (hasInter) {
                wrap &&
                ['resize', 'sf-loader-ready'].forEach((event) => {
                    window.addEventListener(event, () => {
                        lockInlineWidth(navLinks, wrap);
                    });
                });
                lockInlineWidth(navLinks, wrap);
            }
        });
    }

    let lastVisibleId = null;
    let scrollDirection = 'down';
    let lastScrollY = window.scrollY;

    window.addEventListener(
        'scroll',
        () => {
            scrollDirection = window.scrollY > lastScrollY ? 'down' : 'up';
            lastScrollY = window.scrollY;
        },
        { passive: true },
    );

    const observer = new IntersectionObserver(
        (entries) => {
            entries.forEach((entry) => {
                const id = entry.target.getAttribute('id');
                const link = document.querySelector(
                    `.sf-side-menu-list-item a[href="#${id}"]`,
                );
                if (!link) return;

                if (entry.isIntersecting) {
                    visibleIds.add(id);
                } else {
                    visibleIds.delete(id);
                }
            });

            let hasActive = false;
            navLinks.forEach((link) => {
                const href = link.getAttribute('href') || '';
                const id = href.startsWith('#') ? href.slice(1) : null;

                if (id && visibleIds.has(id)) {
                    hasActive = true;
                    link.classList.add('active');
                    lastVisibleId = id;
                } else {
                    link.classList.remove('active');
                }
            });
            if (!hasActive) {
                if (lastVisibleId) {
                    const fallbackLink = document.querySelector(
                        `.sf-side-menu-list-item a[href="#${lastVisibleId}"]`,
                    );
                    if (scrollDirection === 'down') {
                        if (fallbackLink) {
                            fallbackLink.classList.add('active');
                        }
                    } else {
                        const prev = Array.from(navLinks).indexOf(fallbackLink) - 1;
                        if (prev > 0) {
                            navLinks[prev].classList.add('active');
                        }
                    }
                } else {
                    let closestId = null;
                    let minDistance = Infinity;
                    const scrollTop = window.scrollY + headerHeight + 1;

                    headers.forEach((h) => {
                        const rect = h.getBoundingClientRect();
                        const top = rect.top + window.scrollY;
                        const distance = Math.abs(scrollTop - top);
                        if (distance < minDistance) {
                            minDistance = distance;
                            closestId = h.id;
                        }
                    });
                    if (closestId) {
                        const closestLink = document.querySelector(
                            `.sf-side-menu-list-item a[href="#${closestId}"]`,
                        );
                        if (closestLink) {
                            closestLink.classList.add('active');
                        }
                    }
                }
            }
        },
        {
            rootMargin: `-${headerHeight}px 0px 0px 0px`,
            threshold: 0,
        },
    );

    headers.forEach((h) => {
        const link = h.querySelector('a');
        if (link) {
            navClick(link, headerHeight, h);
        }
        observer.observe(h);
    });
}

function navClick(link, headerHeight, head = null) {
    link.addEventListener('click', (event) => {
        event.preventDefault();
        const href = link.getAttribute('href');
        if (!head) {
            head = document.getElementById(`${href.replace('#', '')}`);
        }
        const elementPosition = head.getBoundingClientRect().top + window.scrollY;
        const offsetPosition = elementPosition - headerHeight;
        history.pushState(null, '', href);
        window.scrollTo({
            top: offsetPosition - 20,
            behavior: 'smooth',
        });
    });
}

initFontSize();

function init() {
    initNavLinks();
    initResize();
    initMenuScrollButtons();
    initSearch();
    scrollToActiveMenu();
    window.addEventListener('sf-loader-ready', () => {
        initReadMode();
    })
}

const runInit = () => init();
if (typeof Turbo !== 'undefined') {
    turboEnable = true;
    document.addEventListener('turbo:load', () => {
        runInit();
    });
} else if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', runInit);
} else {
    runInit();
}

// alert('Поправить Анимацию сжимания и разжимания контейнера для турбо');
function getInitialState(name) {
    const savedState = localStorage.getItem(name);
    return savedState ? savedState === 'true' : false;
}

if (window.sfJsLang && window.sfJsLang.copy && window.sfJsLang['copy done']) {
    window.addEventListener('Copy:beforeRender', (event) => {
        event.detail.params.text = window.sfJsLang.copy;
        event.detail.params.done = window.sfJsLang['copy done'];
    });
}

function initFontSize() {
    let state = localStorage.getItem('sf-fontSize');
    if (state) {
        state = JSON.parse(state);
        if (state.className) {
            document.documentElement.classList.add(state.className);
        }
        document.documentElement.style.fontSize = state.size;
    }
    window.addEventListener('Radio:render', (event) => {
        const { detail } = event;
        const { html } = detail;
        let key = 0;
        if (html) {
            switch (html.id) {
                case 'size_switch':
                    const inputs = html.querySelectorAll('input');
                    inputs &&
                    inputs.forEach((input, index) => {
                        const size = index === 0 ? '14px' : index === 1 ? '16px' : '18px';
                        const className =
                            index === 0
                                ? 'sf-font-small'
                                : index === 1
                                    ? false
                                    : 'sf-font-big';
                        if (state && state.index === index) {
                            key = index;
                            input.checked = true;
                        }
                        input.addEventListener('change', () => {
                            document.documentElement.style.fontSize = size;
                            if (className) {
                                document.documentElement.classList.add(className);
                            } else {
                                document.documentElement.classList.remove(
                                    'sf-font-small',
                                    'sf-font-big',
                                );
                            }
                            localStorage.setItem(
                                'sf-fontSize',
                                JSON.stringify({
                                    index: index,
                                    className: className,
                                    size: size,
                                }),
                            );
                        });
                    });
                    break;
                default:
                    break;
            }
        }
        if (typeof detail.radioChange === 'function') {
            detail.radioChange(key);
        }
    });
}

function initReadMode() {
    const resizeObserver = new SizeObserver();
    resizeObserver.init();
    const state = getInitialState('readMode');
    if (state) {
        const button = document.getElementById('read_mode');
        if (button) {
            applyReadMode(button);
        }
    }
}

function initResize() {
    const body = document.querySelector('body');

    const readState = getInitialState('readMode');
    const isExpanded = getInitialState('expanded');

    if (isExpanded && !readState) {
        setResize(body, isExpanded);
    }
}

function getNextOrPrevHiddenItem(container, items, next) {
    if (!items.length) return null;

    const viewportStart = container.scrollLeft;
    const viewportEnd = viewportStart + container.clientWidth;
    const active = container.querySelector('.active');
    if (active) {
        active.classList.remove('active');
    }

    if (next) {
        return items.find(
            (item) => item.offsetLeft + item.clientWidth > viewportEnd + 1,
        ) ?? null;
    }

    for (let i = items.length - 1; i >= 0; i--) {
        const item = items[i];
        if (item.offsetLeft < viewportStart - 1) {
            return item;
        }
    }

    return null;
}

window.updateMenuScrollButtons = function updateMenuScrollButtons() {
    const menu = document.getElementById('top_menu');
    const container = document.querySelector('.dc-menu-container');
    const leftBtn = document.querySelector('.dc-menu-scroll.left');
    const rightBtn = document.querySelector('.dc-menu-scroll.right');

    if (!menu || !container || (!leftBtn && !rightBtn)) return;

    const epsilon = 4;
    const maxScroll = menu.scrollWidth - menu.clientWidth;
    if (maxScroll <= epsilon) {
        leftBtn?.classList.add('hidden');
        rightBtn?.classList.add('hidden');
        container.classList.remove('p-left-5', 'p-right-5');
        return;
    }

    const atStart = menu.scrollLeft <= epsilon;
    const atEnd = menu.scrollLeft >= maxScroll - epsilon;

    if (leftBtn) {
        leftBtn.classList.toggle('hidden', atStart);
    }
    if (rightBtn) {
        rightBtn.classList.toggle('hidden', atEnd);
    }

    container.classList.toggle('p-left-5', !atStart);
    container.classList.toggle('p-right-5', !atEnd);
};

window.menuScroll = function (button, next = true) {
    const menu = document.getElementById('top_menu');
    const container = document.querySelector('.dc-menu-container');
    if (!menu || !container) return;
    const items = Array.from(menu.children);
    const nextHidden = getNextOrPrevHiddenItem(menu, items, next);
    if (nextHidden) {
        menu.scrollTo({
            left: nextHidden.offsetLeft,
            behavior: 'smooth',
        });
        nextHidden.classList.add('active');
        // Ensure button state updates after smooth scroll completes.
        requestAnimationFrame(updateMenuScrollButtons);
        setTimeout(updateMenuScrollButtons, 250);
    } else if (!next) {
        // Nothing left to the start: snap to beginning.
        menu.scrollTo({ left: 0, behavior: 'smooth' });
        requestAnimationFrame(updateMenuScrollButtons);
        setTimeout(updateMenuScrollButtons, 250);
    } else {
        // Nothing more to the right: snap to end.
        const maxScroll = menu.scrollWidth - menu.clientWidth;
        menu.scrollTo({ left: maxScroll, behavior: 'smooth' });
        requestAnimationFrame(updateMenuScrollButtons);
        setTimeout(updateMenuScrollButtons, 250);
    }
};

function initMenuScrollButtons() {
    const menu = document.getElementById('top_menu');
    if (!menu) return;
    const rerender = () => requestAnimationFrame(updateMenuScrollButtons);
    menu.addEventListener('scroll', rerender, { passive: true });
    window.addEventListener('resize', rerender);
    updateMenuScrollButtons();
}

function setResize(container, isExpanded) {
    if (isExpanded) {
        container.classList.add('max-container-8');
        container.classList.remove('max-container-6');
    } else {
        container.classList.add('max-container-6');
        container.classList.remove('max-container-8');
    }
    localStorage.setItem('expanded', isExpanded.toString());
}

window.toggleResize = function () {
    const isExpanded = !getInitialState('expanded'),
        body = document.querySelector('body');
    setResize(body, isExpanded);
};

window.applyReadMode = function (button) {
    const icon = button.children[0];
    const header = document.querySelector('header');
    const body = document.body;
    const navMenu = document.querySelector('.sf-nav-menu--left');
    const headerRight = header.querySelector('.header--right');
    const segmentButton = document.getElementById('sf_segment');
    const sideMenu = document.getElementById('side_menu');
    const mainContainer = document.querySelector('.container--main');
    const sideMenuNavigation = document.querySelector('.side-menu-navigation');
    [header, navMenu, sideMenuNavigation].forEach((item) => {
        if (item) {
            item.classList.toggle('hidden');
        }
    });

    [mainContainer, sideMenu].forEach((item) => {
        if (item) {
            item.classList.toggle('read');
        }
    });

    if (icon) {
        if (mainContainer.classList.contains('read')) {
            icon.textContent = 'fullscreen_exit';
            body.classList.remove('max-container-8', 'max-container-6');
            body.classList.add('max-container-1', 'read');
            button.classList.add('read');
            segmentButton.classList.add('hidden');
            mainContainer.parentNode.insertBefore(button, sideMenu);
            requestAnimationFrame(() => setReadModePosition(mainContainer, button));
        } else {
            icon.textContent = 'fullscreen';
            body.classList.remove('max-container-1', 'read');
            const isExpanded = getInitialState('expanded');
            body.classList.add(`max-container-${isExpanded ? '8' : '6'}`);
            button.classList.remove('read');
            segmentButton.classList.remove('hidden');
            sideMenu.removeAttribute('style');
            headerRight.prepend(button);
        }
        toggleLinksWidth();
    }
    localStorage.setItem(
        'readMode',
        String(mainContainer.classList.contains('read')),
    );
};

window.navOpen = function () {
    const nav = document.getElementById('side_menu');
    const mainMenu = document.getElementById('main_menu');
    nav && nav.classList.toggle('active');
    if (nav.classList.contains('active')) {
        document.body.classList.add('overflow-hidden');
    } else {
        document.body.classList.remove('overflow-hidden');
    }
    mainMenu && mainMenu.classList.remove('active');
};

window.langOpen = function (item) {
    const language_switch_panel = item.parentElement.querySelector(
        '.sf-language-switch--language-panel',
    );
    language_switch_panel.classList.toggle('hidden');
};

window.langSwitch = function (button) {
    const newLocale = button.dataset.locale;
    if (newLocale !== locale) {
        document.cookie = `locale=${newLocale}; path=/; max-age=31536000`; // 1 year
        const currentPath = window.location.pathname.split('/');
        const currentLocale = locale;
        window.location.href = currentPath
            .map((segment) => (segment === currentLocale ? newLocale : segment))
            .join('/');
    }
};

function lockInlineWidth(items, wrap) {
    if (!items.length || !wrap) return;

    const measureHost = document.createElement('div');
    measureHost.style.position = 'absolute';
    measureHost.style.visibility = 'hidden';
    measureHost.style.pointerEvents = 'none';
    measureHost.style.left = '-9999px';
    measureHost.style.top = '-9999px';
    measureHost.style.width = `${wrap.clientWidth}px`;

    document.body.appendChild(measureHost);

    items.forEach((el) => {
        const list = el.closest('.sf-side-menu-list-item');
        const item = list?.querySelector('.sf-side_item');
        if (!item) return;
        item.style.maxWidth = '';

        const probe = list.cloneNode(true);
        probe.style.position = 'static';
        probe.style.visibility = 'visible';
        probe.style.fontWeight = '700';
        measureHost.replaceChildren(probe);

        const span = probe.querySelector('span');
        const w700 =
            span?.getBoundingClientRect().width || item.getBoundingClientRect().width;
        item.style.maxWidth = `${w700}px`;
    });

    document.body.removeChild(measureHost);
}

window.addEventListener('click', function (e) {
    const floatContainers = document.querySelectorAll('.sf-float-wrap');
    if (!floatContainers.length) {
        return false;
    }

    floatContainers.forEach((container) => {
        if (e.target !== container && !container.contains(e.target)) {
            container.classList.remove('active');
        }
    });
    const langContainer = document.querySelector(
        '.sf-language-switch--container',
    );
    const menu = langContainer?.querySelector(
        '.sf-language-switch--language-panel-show',
    );
    if (!menu) {
        return false;
    }
    if (
        langContainer &&
        e.target !== langContainer &&
        !langContainer.contains(e.target)
    ) {
        document
            .querySelector('.sf-language-switch--language-panel')
            .classList.remove('sf-language-switch--language-panel-show');
    }
});
