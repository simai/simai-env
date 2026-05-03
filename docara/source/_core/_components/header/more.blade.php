<div class="sf-more-wrap sf-float-wrap">
    <button onclick="toggleFloat(this)" title="{{$page->translate('actions')}}" class=" sf-icon-button sf-icon-button--icon radius-default sf-button-settings  sf-icon-button--size-1 sf-icon-button--link sf-icon-button--on-surface">
        <i class="sf-icon">more_vert</i>
    </button>
    <div class="sf-more-menu bg-surface-overlay">
        <div class="flex sf-more-menu_item">
            <button onclick="window.open(`{{$page->gitHubUrl()}}`, '_blank')" title="Изменить статью" class="sf-button flex text-start sf-button-settings sf-button--size-1 sf-button--link sf-button--on-surface">
                <i class="sf-icon">edit</i>
                <span class="sf-button-text-container sf-button-text">{{$page->translate('edit article')}}</span>
            </button>
        </div>
        <div class="flex sf-more-menu_item">
            <button onclick="setIssue(`{{$page->github}}`)" title="Сообщить об ошибке" class="sf-button flex text-start sf-button-settings  sf-button--size-1 sf-button--link sf-button--on-surface">
                <i class="sf-icon">bug_report</i>
                <span class="sf-button-text-container sf-button-text">{{$page->translate('report a bug')}}</span>
            </button>
        </div>
    </div>
</div>
