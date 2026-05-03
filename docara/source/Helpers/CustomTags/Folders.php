<?php

namespace App\Helpers\CustomTags;

use League\CommonMark\Renderer\HtmlRenderer;
use Simai\Docara\CustomTags\BaseTag;
use Simai\Docara\CustomTags\CustomTagNode;

class Folders extends BaseTag
{
    private static bool $scriptAdded = false;

    public function __construct()
    {
        $this->isContainer = false;
    }

    public function type(): string
    {
        return 'folders';
    }

    public function allowNestingSame(): bool
    {
        return false;
    }

    private function isImageFile(string $filename): bool
    {

        static $imageExtensions = [
            'jpg', 'jpeg', 'png', 'gif', 'webp',
            'bmp', 'tiff', 'tif', 'svg', 'ico',
            'avif', 'heic', 'heif',
        ];

        $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));

        return in_array($ext, $imageExtensions, true);
    }

    public function baseAttrs(): array
    {
        return ['class' => 'files'];
    }

    public function renderer(): ?callable
    {
        return [$this, 'render'];
    }

    private function folderTemplate(string $text, bool $hasChildren, bool $focus): string
    {
        $chevron = $hasChildren ? '<i class="sf-icon sf-folder-chevron">chevron_right</i>' : '';
        $justify = $hasChildren ? '' : 'content-main-end';
        $event = $hasChildren ? 'onclick="toggleSfFolder(this);"' : '';
        $open = $hasChildren ? ' open' : '';
        $focusClass = $focus ? 'sf-files-focus' : '';

        return "<div class='sf-folder p-left-3 flex flex-col gap-1/3{$open}'><div {$event} class='sf-folder-item flex items-cross-center gap-1/2 $focusClass'><div class='sf-folder-icon sf-text-2 absolute flex {$justify}'>{$chevron}<i class='sf-icon sf-icon-filled'>folder</i></div><div class='m-0 sf-text-1/2'>{$text}</div></div>";
    }

    private function fileTemplate(string $text, bool $focus): string
    {
        $isImage = $this->isImageFile($text);
        $icon = $isImage ? 'image' : 'docs';
        $focusClass = $focus ? 'sf-files-focus' : '';

        return "<div class='sf-file p-left-3 flex $focusClass'><div class='flex items-cross-center gap-1/2'><div class='sf-file-icon sf-text-2 absolute flex'><i class='sf-icon'>{$icon}</i></div><div class='m-0 sf-text-1/2'>$text</div></div></div>";
    }

    private function renderTree(array $rows): string
    {
        $html = '<div class="sf-files-wrap"><div class="sf-files-main"><div class="sf-files flex flex-col gap-1/3">';
        $stack = [];

        foreach ($rows as $row) {
            $node = reset($row);
            $folders = $node['folders'] ?? null;
            $files = $node['files'] ?? null;

            $level = (int) ($folders['level'] ?? 0);

            while (! empty($stack) && end($stack)['level'] >= $level) {
                $last = array_pop($stack);
                $html .= $last['close'];
            }

            if ($folders) {

                $name = htmlspecialchars($folders['name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
                $ancestorFocus = false;
                foreach (array_reverse($stack) as $item) {
                    if ($item['level'] < $level && $item['focus']) {
                        $ancestorFocus = true;
                        break;
                    }
                }
                $folderFocus = $folders['focus'] || $ancestorFocus;

                $html .= $this->folderTemplate($name, $folders['hasChildren'], $folderFocus);

                if (! empty($folders['files'])) {
                    foreach ($folders['files'] as $file) {
                        $fileName = htmlspecialchars($file['name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
                        $focus = $folderFocus || $file['focus'];
                        $html .= $this->fileTemplate($fileName, $focus);
                    }
                }

                $stack[] = [
                    'level' => $level,
                    'focus' => $folderFocus,
                    'close' => '</div>',
                ];
            }

            if ($files && ! $folders) {
                foreach ($files as $file) {
                    $fileName = htmlspecialchars($file['name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
                    $focus = $file['focus'];
                    $html .= $this->fileTemplate($fileName, $focus);
                }
            }
        }

        while (! empty($stack)) {
            $last = array_pop($stack);
            $html .= $last['close'];
        }

        $html .= '</div></div></div>';

        if (! self::$scriptAdded) {
            self::$scriptAdded = true;
            $script = file_get_contents(dirname(__DIR__) . '/js/folders.js');
            $html .= '<script type="text/javascript">' . $script . '</script>';
        }

        return $html;
    }

    public function render(CustomTagNode $node, HtmlRenderer $render): string
    {
        $raw = $node->getMeta()['raw'];
        $lines = preg_split('/\r?\n/', trim($raw));

        $tree = [];
        $folderStack = [];

        foreach ($lines as $key => $line) {
            if (! trim($line)) {
                continue;
            }

            $indent = strspn($line, " \t");
            $trimmed = trim($line);

            if (preg_match('/^-(?!-)\s+(.+?)(?:\s*\((current|focus|\*)\))?$/', $trimmed, $m)) {
                $name = $m[1] ?? '';
                $focus = $m[2] ?? false;
                $tree[$key][$indent]['folders'] = [
                    'name' => $name,
                    'level' => $indent,
                    'focus' => $focus,
                    'hasChildren' => false,
                    'files' => [],
                ];

                $parent = null;
                $parentLevel = null;

                if (! empty($folderStack)) {
                    foreach ($folderStack as $lvl => $info) {
                        if ($lvl < $indent && ($parentLevel === null || $lvl > $parentLevel)) {
                            $parentLevel = $lvl;
                            $parent = $info;
                        }
                    }
                }

                if ($parent !== null) {
                    $tree[$parent['row']][$parentLevel]['folders']['hasChildren'] = true;
                }

                foreach (array_keys($folderStack) as $lvl) {
                    if ($lvl >= $indent) {
                        unset($folderStack[$lvl]);
                    }
                }

                $folderStack[$indent] = [
                    'row' => $key,
                    'level' => $indent,
                ];

                continue;
            }

            if (preg_match('/^--(?!-)\s+(.+?)(?:\s*\((current|focus|\*)\))?$/', $trimmed, $m)) {
                $name = $m[1];
                $focus = $m[2] ?? false;

                $parent = null;
                $parentLevel = null;

                if (! empty($folderStack)) {

                    foreach ($folderStack as $lvl => $info) {
                        if ($lvl < $indent && ($parentLevel === null || $lvl > $parentLevel)) {
                            $parentLevel = $lvl;
                            $parent = $info;
                        }
                    }
                }

                if ($parent !== null) {

                    $tree[$parent['row']][$parentLevel]['folders']['hasChildren'] = true;
                    $tree[$parent['row']][$parentLevel]['folders']['files'][] = [
                        'name' => $name,
                        'focus' => $focus,
                    ];
                } else {
                    $tree[$key][$indent]['files'][] = [
                        'name' => $name,
                        'focus' => $focus,
                    ];
                }
            }
        }
        $html = $this->renderTree($tree);
        $doc = $node->getDocument();
        if ($doc && ! $doc->data->has('folders_script')) {
            $doc->data->set('folders_script', true);
            $script = file_get_contents(dirname(__DIR__) . '/js/folders.js');
            $html .= '<script type="text/javascript">' . $script . '</script>';
        }

        return $html;
    }
}
