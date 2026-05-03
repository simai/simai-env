<?php

use Illuminate\Support\Str;

$projectRoot = getcwd();

$layoutConfiguration = [
    'base' => [
        'header' => [
            'enabled' => true,
            'blocks' => [
                'logo' => ['enabled' => true],
                'topMenu' => ['enabled' => true],
                'search' => ['enabled' => true],
                'toolbar' => [
                    'enabled' => true,
                    'items' => [
                        ['type' => 'button', 'label' => 'Feedback', 'action' => '/feedback'],
                        [
                            'type' => 'menu',
                            'label' => 'Share',
                            'items' => [
                                ['label' => 'Copy link', 'action' => 'copy'],
                                ['label' => 'Export PDF', 'action' => '/export.pdf'],
                            ],
                        ],
                    ],
                ],
            ],
        ],
        'asideLeft' => [
            'enabled' => true,
            'blocks' => [
                'menu' => ['enabled' => true],
                'tools' => [
                    'enabled' => false,
                    'align' => 'bottom',
                    'content' => null,
                ],
            ],
        ],
        'main' => [
            'innerContent' => ['enabled' => true],
            'outerContent' => ['enabled' => false, 'mode' => 'iframe', 'src' => null],
        ],
        'asideRight' => [
            'enabled' => true,
            'blocks' => [
                'navigation' => ['enabled' => true],
            ],
        ],
        'footer' => ['enabled' => false],
        'floating' => [
            'enabled' => true,
            'fabBackToTop' => ['enabled' => true],
        ],
    ],
];

return [
    'baseUrl' => rtrim((string) (getenv('DOCARA_BASE_URL') ?: ''), '/'),
    'production' => false,
    'modulePath' => getenv('DOCARA_MODULE_PATH') ?: null,
    'env' => getenv(),
    'category' => false,
    'cache' => false,
    'moduleCache' => false,
    'cachePath' => $projectRoot . '/.cache',
    'siteName' => 'simai-env',
    'siteDescription' => 'Documentation for simai-env: user workflows, CLI reference, architecture, and operations.',
    'github' => 'https://github.com/simai/simai-env',
    'githubEditBasePath' => 'docara',
    'turbo' => false,
    'locales' => [
        'en' => 'English',
    ],
    'pretty' => true,
    'defaultLocale' => 'en',
    'lang_path' => 'source/lang',
    'tags' => ['ExampleTag', 'Folders', 'ListWrap'],
    'getNavItems' => function ($page) {
        return $page->configurator->getPrevAndNext($page->getPath(), $page->locale());
    },
    'getMenu' => function ($page) {
        $locale = $page->locale();
        if ($page->category) {
            $path = collect(explode('/', trim(str_replace('\\', '/', $page->getPath()), '/')))
                ->take(2)->toArray();

            return $page->configurator->getMenu($locale, $path);
        } else {
            return $page->configurator->getMenu($locale);
        }
    },
    'generateBreadcrumbs' => function ($page) {
        $currentPath = trim($page->getPath(), '/');
        $locale = $page->locale();
        $segments = $currentPath === '' ? [] : explode('/', $currentPath);

        return $page->configurator->generateBreadCrumbs($locale, $segments);
    },
    'getJsTranslations' => function ($page) {
        $locale = $page->locale();

        return $page->configurator->getJsTranslations($locale);
    },
    'getTest' => function ($page) {
        return $page->test ?? ['test' => 123];
    },
    'locale' => function ($page) {
        $path = str_replace('\\', '/', $page->getPath());
        $locale = explode('/', $path);
        $current = $page->defaultLocale;
        $locales = array_keys($page->locales->toArray());
        foreach ($locale as $segment) {
            if (in_array($segment, $locales)) {
                $current = $segment;
                break;
            }
        }

        return $current;
    },
    'gitHubUrl' => function ($page) {
        $url = $page->configurator->getGitHubUrl($page);
        $basePath = trim((string) ($page->githubEditBasePath ?? ''), '/');

        if ($basePath === '' || ! str_contains($url, '/blob/main/')) {
            return $url;
        }

        return str_replace('/blob/main/', '/blob/main/' . $basePath . '/', $url);
    },
    'isHome' => function ($page) {
        $current = trim($page->getPath(), '/');

        return $current === $page->locale();
    },
    'collections' => require_once ('source/_core/collections.php'),
    'isActive' => function ($page, $path) {
        return Str::endsWith(trimPath($page->getPath()), trimPath($path));
    },
    'translate' => function ($page, $text) {
        return $page->configurator->getTranslate(trim($text), $page->locale());
    },
    'isActiveParent' => function ($page, $node): bool {
        $currentPath = $page->getPath();
        if ($node['path'] === $currentPath) {
            return true;
        }
        foreach ($node['children'] as $child) {
            if ($page->isActiveParent($child, $currentPath)) {
                return true;
            }
        }

        return false;
    },

    'layout' => $layoutConfiguration,
];
