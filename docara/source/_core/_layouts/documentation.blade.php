@extends('_core._layouts.master')


@section('body')
    <section class="flex-1">
        @include('_core._components._nav.breadcrumbs')

        <div class="flex flex-col lg:flex-row">
            <div class="main--content" v-pre>
                @yield('content')
            </div>
        </div>
    </section>
    @include('_core._components._nav.bottom-nav')
@endsection
