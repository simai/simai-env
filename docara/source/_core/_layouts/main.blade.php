<main role="main" class="w-full flex flex-auto justify-center container p-inline-start-1 p-inline-end-1 m-auto">
    @includeWhen(layout_enabled($page, 'asideLeft'), '_core._components.aside.aside-left', ['section' => layout_section($page, 'asideLeft.blocks')])

    @includeWhen(layout_enabled($page, 'main'), '_core._layouts.article')

    @includeWhen(layout_enabled($page, 'asideRight'), '_core._components.aside.aside-right', ['section' => layout_section($page, 'asideRight.blocks')])
</main>
<div data-theme-builder="drawer" right="c8" bottom="e1" class="sf-theme-builder z-9"></div>
