#include "pch.h"

#include "MainWindow.xaml.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace winrt::OpenSVN::implementation {

MainWindow::MainWindow() {
    InitializeComponent();
    ShowSection(L"repository");
    Navigation.SelectedItem(Navigation.MenuItems().GetAt(0));
}

void MainWindow::OnNavigationSelectionChanged(NavigationView const&,
                                              NavigationViewSelectionChangedEventArgs const& args) {
    if (const auto item = args.SelectedItem().try_as<NavigationViewItem>()) {
        ShowSection(unbox_value<hstring>(item.Tag()));
    }
}

void MainWindow::ShowSection(std::wstring_view tag) {
    // Placeholders, on purpose: stage 4 replaces each branch with a real page.
    // Writing the copy here keeps the empty state honest instead of showing an
    // empty grey rectangle that looks like a bug.
    hstring title;
    hstring body;

    if (tag == L"repository") {
        title = L"Repository";
        body = L"打开或检出工作副本后，这里显示仓库地址、根路径、当前修订与工作副本锁状态。";
    } else if (tag == L"changes") {
        title = L"Changes";
        body = L"列出有改动的路径，区分文本、属性、树冲突，以及仓库文件锁与工作副本内部锁。";
    } else if (tag == L"history") {
        title = L"History";
        body = L"读取 svn log --xml -v，显示作者、时间、提交说明与受影响路径。";
    } else if (tag == L"diff") {
        title = L"Diff";
        body = L"显示所选文件的统一差异；只读，不修改工作副本。";
    } else if (tag == L"commit") {
        title = L"Commit";
        body = L"选择要提交的路径并填写说明；提交前会重新读取状态，避免提交到过期的工作副本。";
    } else {
        title = L"Settings";
        body = L"指定 svn 可执行文件位置、查看版本与支持区间；不在此处保存密码。";
    }

    SectionTitle().Text(title);
    SectionBody().Text(body);
}

}  // namespace winrt::OpenSVN::implementation
