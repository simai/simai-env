import setReadModePosition from "./functions";

export class SizeObserver {
    constructor() {
        this.lastWidth = null;
        this.setTopMenu = false;
        this.setCollapsed = false;
        this.menuResizeQueued = false;
        this.menuResizeWidth = null;
        this.mainResizeQueued = false;
        this.mainResizeWidth = null;
        this.menuWrap = document.querySelector(".sf-menu-container");
        this.menu = this.menuWrap?.querySelector("#top_menu") ?? null;
    this.readState = false;
    this.headerWrap = document.querySelector(".header--wrap");
    this.body = document.querySelector("body");
    this.main = document.querySelector("main");
    this.readMode = document.getElementById("read_mode");
    this.navMenu = document.getElementById("main_menu");
    this.navMenuHadBetween = !!this.navMenu?.classList.contains("content-main-between");
    this.fallbackNavMenu = null;
    this.fallbackNavCreated = false;
    if (this.headerWrap) {
      this.logo = this.headerWrap.querySelector("a.logo");
    } else {
      this.logo = null;
    }
        this.bindTurboLifecycle();
        this.setObserver();
    }

  refreshElements = () => {
    this.menuWrap = document.querySelector(".sf-menu-container");
    this.menu = this.menuWrap?.querySelector("#top_menu") ?? null;
    this.headerWrap = document.querySelector(".header--wrap");
    this.logo = this.headerWrap?.querySelector("a.logo") ?? null;
    this.navMenu = document.getElementById("main_menu");
    this.navMenuHadBetween = !!this.navMenu?.classList.contains("content-main-between");
    this.body = document.querySelector("body");
    this.main = document.querySelector("main");
    this.readMode = document.getElementById("read_mode");
  };

  createNavMenuFallback = () => {
    // When no left menu exists (e.g., index page), create a mobile off-canvas container
    // so top menu can still be moved there at small widths.
    if (this.fallbackNavMenu) return this.fallbackNavMenu;
    const aside = document.createElement("aside");
    aside.id = "main_menu";
    aside.className =
        "sf-nav-menu w-full sf-nav-menu--left flex flex-col content-main-between p-0 lg:p-y-3 gap-2 sticky overflow-auto";
    document.body.appendChild(aside);
    this.fallbackNavMenu = aside;
    this.fallbackNavCreated = true;
    this.navMenuHadBetween = true;
    return aside;
  };

  removeNavMenuFallback = () => {
    if (this.fallbackNavCreated && this.fallbackNavMenu) {
      this.fallbackNavMenu.remove();
      this.fallbackNavMenu = null;
      this.fallbackNavCreated = false;
      this.navMenu = document.getElementById("main_menu");
    }
  };

  toggleNavMenuClasses = (inNavMenu) => {
    if (this.menuWrap) {
      if (inNavMenu) {
        this.menuWrap.classList.remove("flex-1");
      } else {
        this.menuWrap.classList.add("flex-1");
      }
    }
    if (this.navMenu && this.navMenuHadBetween) {
      if (inNavMenu) {
        this.navMenu.classList.remove("content-main-between");
      } else {
        this.navMenu.classList.add("content-main-between");
      }
    }
  };

  bindTurboLifecycle = () => {
    if (typeof Turbo === "undefined") return;
    document.addEventListener("turbo:before-render", () =>
      this.disconnect(),
    );
        document.addEventListener("turbo:load", () => {
            this.refreshElements();
            this.setObserver();
            this.init();
        });
    };

    disconnect = () => {
        this.menuObserver?.disconnect();
        this.mainObserver?.disconnect();
    };

    mutate = (fn) => requestAnimationFrame(fn);
    applyMenuState = (width) => {
        if (!this.menuWrap || !this.menu) {
            this.refreshElements();
        }
        if (!this.menuWrap || !this.menu) return;

        const fallbackWidth = width > 0 ? width : window.innerWidth;
        const available =
            this.menuWrap?.getBoundingClientRect().width ?? fallbackWidth;
        const required = this.menu?.scrollWidth || fallbackWidth;
        const shouldCollapse = required > available;
        if (shouldCollapse) {
            if (this.setCollapsed) return;
            this.mutate(() => {
                this.menuWrap.classList.add("menu--collapsed", "p-right-5");
                window.updateMenuScrollButtons?.();
            });
            this.setCollapsed = true;
        } else {
            if (!this.setCollapsed) return;
            this.mutate(() => {
                this.menuWrap.classList.remove("menu--collapsed", "p-right-5");
                window.updateMenuScrollButtons?.();
            });
            this.setCollapsed = false;
        }
    };
    applyMainWidth = (width) => {
        if (!this.menuWrap || !this.navMenu || !this.logo) {
            this.refreshElements();
        }
    const w = width | 0;
    if (w === this.lastWidth) return;
    this.lastWidth = w;
    this.placeReadModeForWidth(w);

    if (w < 980 && w > 768) {
      if (this.setTopMenu && this.menuWrap && this.logo) {
        this.setTopMenu = false;
        this.mutate(() => {
          this.toggleNavMenuClasses(false);
          this.logo.after(this.menuWrap);
        });
      }
    } else if (w <= 768) {
      if (!this.navMenu) {
        this.navMenu = this.createNavMenuFallback();
      }
      if (!this.setTopMenu && this.menuWrap && this.navMenu) {
        this.setTopMenu = true;
        this.mutate(() => {
          this.toggleNavMenuClasses(true);
          this.navMenu?.prepend(this.menuWrap);
        });
      }
    } else {
      if (this.setTopMenu && this.menuWrap && this.logo) {
        this.setTopMenu = false;
        this.mutate(() => {
          this.toggleNavMenuClasses(false);
          this.logo.after(this.menuWrap);
        });
      }
      // On wider viewports, remove temporary navMenu if we created it.
      if (this.fallbackNavCreated) {
        this.removeNavMenuFallback();
      }
    }
  };
    placeReadModeForWidth = (width) => {
        if (!this.readMode) return;
        if (width < 980) {
            this.mutate(() => {
                requestAnimationFrame(() => {
                    if (!this.main || !this.readMode) return;
                    setReadModePosition(this.main, this.readMode);
                });
                if (!this.readState) {
                    this.readState = true;
                }
            });
        } else {
            this.mutate(() => {
                requestAnimationFrame(() => {
                    if (!this.main || !this.readMode || !this.readState) return;
                    setReadModePosition(this.main, this.readMode);
                });
                if (this.readState) {
                    this.readState = false;
                }
            });
        }
    };
    setObserver = () => {
        this.disconnect();
        if (this.menuWrap) {
            this.menuObserver = new ResizeObserver((entries) => {
                for (const entry of entries) {
                    this.scheduleMenuResize(entry.contentRect.width);
                }
            });
            this.menuObserver.observe(this.menuWrap);
        }

        this.mainObserver = new ResizeObserver((entries) => {
            for (const entry of entries) {
                this.scheduleMainResize(entry.contentRect.width);
            }
        });
        const target = this.body ?? document.documentElement;
        if (target) {
            this.mainObserver.observe(target);
        }
    };

    scheduleMenuResize = (width) => {
        this.menuResizeWidth = width;
        if (this.menuResizeQueued) return;
        this.menuResizeQueued = true;
        requestAnimationFrame(() => {
            this.menuResizeQueued = false;
            this.applyMenuState(this.menuResizeWidth);
        });
    };

    scheduleMainResize = (width) => {
        this.mainResizeWidth = width;
        if (this.mainResizeQueued) return;
        this.mainResizeQueued = true;
        requestAnimationFrame(() => {
            this.mainResizeQueued = false;
            this.applyMainWidth(this.mainResizeWidth);
        });
    };

    init() {
        const initialWidth =
            this.body?.getBoundingClientRect().width ?? window.innerWidth;
        this.applyMainWidth(initialWidth);

        requestAnimationFrame(() => {
            const menuWidth =
                this.menuWrap?.getBoundingClientRect().width ??
                window.innerWidth;
            this.applyMenuState(menuWidth);
        });
    }
}
