;(function (window, document) {
    'use strict';
    function waitForElement(selector, timeout) {
        return new Promise(function (resolve, reject) {
            const el = document.querySelector(selector);
            if (el) return resolve(el);

            const observer = new MutationObserver(function () {
                const el = document.querySelector(selector);
                if (el) {
                    observer.disconnect();
                    resolve(el);
                }
            });

            observer.observe(document.documentElement, {
                childList: true,
                subtree: true,
            });

            if (timeout != null) {
                setTimeout(function () {
                    observer.disconnect();
                    reject(
                        new Error('StickyOffsets: element "' + selector + '" not found'),
                    );
                }, timeout);
            }
        });
    }

    function setVar(name, value) {
        document.documentElement.style.setProperty(name, value);
    }

    function initResizeObserver(header = null, footer = null) {
        const update = function () {
            if (header) {
                const h = header.offsetHeight || 0;
                setVar('--sf-header-height', h + 'px');
            }

            if (footer) {
                const f = footer.offsetHeight || 0;
                setVar('--sf-footer-height', f + 'px');
            }
        };

        update();

        if ('ResizeObserver' in window) {
            const ro = new ResizeObserver(update);
            if (header) ro.observe(header);
            if (footer) ro.observe(footer);
        } else {

            window.addEventListener('resize', update);
        }
    }

    function initStickyOffsets(options) {
        options = options || {};
        const headerSelector = options.headerSelector || 'header';
        const footerSelector = options.footerSelector || 'footer';
        const timeout = typeof options.timeout === 'undefined' ? 0 : options.timeout;

        const headerPromise = waitForElement(headerSelector, timeout).catch(function () {
            console.warn('StickyOffsets: header not found by selector', headerSelector);
            return null;
        });

        const footerPromise = waitForElement(footerSelector, timeout).catch(function () {

            return null;
        });

        Promise.allSettled([headerPromise, footerPromise]).then(function (res) {
            const header = res[0].status === 'fulfilled' ? res[0].value : null;
            const footer = res[1].status === 'fulfilled' ? res[1].value : null;
            if (!header && !footer) return;
            initResizeObserver(header, footer);
        });
    }


    window.SfStickyOffsets = {
        init: initStickyOffsets,
    };


    const run = () => initStickyOffsets();

    if (typeof Turbo !== 'undefined') {
        document.addEventListener('turbo:load', run);
    } else if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', run);
    } else {
        run();
    }
})(window, document);
