<?php

namespace App\Helpers\CustomTags;

use League\CommonMark\Renderer\HtmlRenderer;
use Simai\Docara\CustomTags\BaseTag;
use Simai\Docara\CustomTags\CustomTagNode;

final class ResponsiveTags extends BaseTag
{
    public function __construct()
    {
        $this->isContainer = false;
    }

    public function type(): string
    {
        return 'rtags';
    }

    public function renderer(): ?callable
    {
        return [$this, 'render'];
    }

    public function render(CustomTagNode $node, HtmlRenderer $render): string
    {
        $attrs = $node->getAttrs();
        $meta = $node->getMeta();
        $raw = trim((string) ($meta['innerRaw'] ?? $meta['raw'] ?? ''));

        $utility = trim((string) ($attrs['utility'] ?? $attrs['name'] ?? ''));
        $bpsRaw = trim((string) ($attrs['bps'] ?? $attrs['breakpoints'] ?? ''));
        $statesRaw = trim((string) ($attrs['states'] ?? $attrs['state'] ?? ''));

        if ($raw !== '') {
            $parts = preg_split('/[\s,|]+/u', $raw, -1, PREG_SPLIT_NO_EMPTY) ?: [];
            if ($utility === '' && isset($parts[0])) {
                $utility = array_shift($parts);
            }
            if ($bpsRaw === '' && $statesRaw === '' && ! empty($parts)) {
                $bpsRaw = implode(' ', $parts);
            }
        }

        if ($utility === '') {
            return '';
        }

        $utility = $this->cleanToken($utility);
        if ($utility === '') {
            return '';
        }

        $modifiers = $this->normalizeModifiers(trim($bpsRaw . ' ' . $statesRaw));
        $utilityHtml = htmlspecialchars($utility, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');

        $html = '<div class="flex flex-wrap m-block-1 gap-1/3">';
        $html .= $this->renderBadge($utilityHtml, true);

        foreach ($modifiers as $modifier) {
            $modifierHtml = htmlspecialchars($modifier, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
            $html .= $this->renderBadge($modifierHtml, false);
        }

        $html .= '</div>';

        return $html;
    }

    private function normalizeModifiers(string $raw): array
    {
        $allowed = [
            // Breakpoints
            'xs',
            'sm',
            'md',
            'lg',
            'xl',
            'xxl',
            // States / pseudo-states
            'hover',
            'focus',
            'focus-visible',
            'focus-within',
            'active',
            'visited',
            'disabled',
            'checked',
            'required',
            'invalid',
            'valid',
            'read-only',
            'open',
            'target',
            // Group/media-like modifiers often used in utility chains
            'group-hover',
            'group-focus',
            'motion-safe',
            'motion-reduce',
            'dark',
            'print',
            'rtl',
            'ltr',
        ];
        $parts = preg_split('/[\s,|]+/u', strtolower(trim($raw)), -1, PREG_SPLIT_NO_EMPTY) ?: [];
        if (empty($parts)) {
            return [];
        }

        $result = [];
        foreach ($parts as $part) {
            if (in_array($part, $allowed, true) && ! in_array($part, $result, true)) {
                $result[] = $part;
            }
        }

        return $result;
    }

    private function cleanToken(string $value): string
    {
        $value = strtolower(trim($value));
        if (! preg_match('/^[a-z0-9\-\/_]+$/', $value)) {
            return '';
        }

        return $value;
    }

    private function renderBadge(string $text, bool $isPrimary): string
    {
        $variant = $isPrimary
            ? 'sf-badge--type-main sf-badge--neutral'
            : 'sf-badge--type-outline sf-badge--neutral';

        return '<span class="sf-badge ' . $variant . ' sf-badge--size-1 flex flex-row flex-nowrap content-main-center items-cross-center">'
            . '<span class="sf-badge-text-container flex items-cross-center">'
            . '<span class="sf-badge-text">' . $text . '</span>'
            . '</span>'
            . '</span>';
    }
}
