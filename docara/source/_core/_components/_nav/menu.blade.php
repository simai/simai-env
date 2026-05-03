@php
    $level = $level ?? 0;
    $menuTree = $menuTree ?? $page->getMenu();
    $paths = $page->configurator->paths;
@endphp

@if($level > 0)
    <ul class="sf-nav-menu-wrap menu-level-{{ $level }} m-top-0 m-bottom-0 p-0">
        @endif
        @foreach ($menuTree as $path => $node)
            @php
                if($node['isLink']) continue;
            @endphp

            @if($level > 0)
                @php
                    $hasPage = in_array($path, $paths);
                    $activeParent = $page->isActiveParent($node);
                    $activeItem = $page->getPath() === $path;
                @endphp
                <li class="sf-nav-menu-element{{$activeParent && !$activeItem ? ' active ' : ' '}}flex text-1 text-start flex-col whitespace-normal">
                    @if (!empty($node['children']))
                        @if($hasPage)
                            <div class="sf-nav-item relative weight-4 p-y-1/3 p-x-2 gap-3 radius-1 flex text-start line-height-1 {{ $activeItem   ? 'visited' : '' }} items-center justify-between">
                                <button class="sf-nav-toggle_button flex items-center p-a6 inline-start-0 top-1/2 absolute translate-y-half"  onclick="toggleNav(this)"
                                        type="button">
                                    <i class="sf-icon">keyboard_arrow_down</i>
                                </button>
                                <a href="{{$path}}" class="sf-nav-button flex" type="button">
                                    <span class="sf-nav-title sf-text-1 weight-4 p-y-1/4">{{ $node['title'] }}</span>
                                </a>
                            </div>
                        @else
                            <button onclick="toggleNav(this)"
                                    class="sf-nav-button sf-nav-item relative weight-4 p-y-1/3 p-x-2 gap-3 radius-1 flex text-start line-height-1 items-center relative" type="button">
                              <span class="sf-nav-toggle_button flex items-center p-a6 inline-start-0 top-1/2 absolute translate-y-half">
                                            <i class="sf-icon">keyboard_arrow_down</i>
                                        </span>
                                <span class="sf-nav-title sf-text-1 weight-4 p-y-1/4">{{ $node['title'] }}</span>
                            </button>
                        @endif
                    @else
                        <a href="{{ $path }}"
                           class="sf-nav-menu-element--link sf-nav-item items-center flex flex-1 radius-1 text-start line-height-1 p-y-1/3 p-x-2 gap-3 sf-nav-menu--lvl{{ $level }} {{ $page->isActive($path) ? 'active' : '' }} text-1 whitespace-normal">
                            <span class="sf-nav-title sf-text-1 weight-4 p-y-1/4">{{ $node['title'] }}</span>
                        </a>
                    @endif
                    @elseif ($node['showInMenu'] && $node['path'])
                        <a href="{{ $path }}"
                           class="sf-nav-menu-element--link sf-nav-item items-center flex flex-1 radius-1 text-start line-height-1 p-y-1/3 p-x-2 gap-3 sf-nav-menu--lvl{{ $level }} {{ $page->isActive($path) ? 'active' : '' }} text-1 whitespace-normal">
                            <span class="sf-nav-title sf-text-1 weight-4 p-y-1/4">{{ $node['title'] }}</span>
                        </a>
                    @endif
                    @if (!empty($node['children']))
                        @include('_core._components._nav.menu', ['menuTree' => $node['children'], 'level' => $level + 1,])
                    @endif
                </li>
                @endforeach
                @if($level > 0)
    </ul>
@endif
