<?php

namespace App\Helpers\CustomTags;

use Simai\Docara\CustomTags\BaseTag;

final class ExampleTag extends BaseTag
{
    public function type(): string
    {
        return 'example';
    }

    public function baseAttrs(): array
    {
        return ['class' => 'example overflow-hidden radius-1/2 overflow-x-auto'];
    }
}
