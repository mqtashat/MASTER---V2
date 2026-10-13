// سجل صفحات النظام (مطابق لجدول pages في قاعدة البيانات) والقائمة الرئيسية (P-2).
export interface PageDef { code: string; name: string; module: string; path: string; ready: boolean }

export const PAGES: PageDef[] = [
  { code: 'P01', name: 'الرئيسية', module: 'الرئيسية', path: '/', ready: true },
  { code: 'P02', name: 'العملاء', module: 'البيانات', path: '/customers', ready: true },
  { code: 'P03', name: 'الموظفون والفرق', module: 'البيانات', path: '/employees', ready: true },
  { code: 'P04', name: 'المنتجات والأسعار', module: 'البيانات', path: '/products', ready: true },
  { code: 'P05', name: 'الرفع الموحد وسجله', module: 'البيانات', path: '/upload', ready: true },
  { code: 'P06', name: 'الفواتير والمرتجعات والتحصيلات', module: 'البيانات', path: '/transactions', ready: true },
  { code: 'P07', name: 'كشف حساب العميل', module: 'الحسابات', path: '/statement', ready: true },
  { code: 'P08', name: 'الذمم الحالية', module: 'الحسابات', path: '/receivables', ready: true },
  { code: 'P08a', name: 'الافتتاحيات والإغلاق السنوي', module: 'الحسابات', path: '/openings', ready: true },
  { code: 'P09', name: 'الإشعارات المدينة والدائنة', module: 'الحسابات', path: '/notes', ready: true },
  { code: 'P10', name: 'أهداف المندوبين', module: 'الأهداف والعمولات', path: '/goals', ready: false },
  { code: 'P10a', name: 'أهداف المشرفين', module: 'الأهداف والعمولات', path: '/goals-supervisors', ready: false },
  { code: 'P11', name: 'قواعد العمولة', module: 'الأهداف والعمولات', path: '/commission-rules', ready: false },
  { code: 'P12', name: 'المكافآت', module: 'الأهداف والعمولات', path: '/rewards', ready: false },
  { code: 'P13', name: 'بطاقات الأداء', module: 'الأهداف والعمولات', path: '/cards', ready: false },
  { code: 'P14', name: 'كشف العمولات', module: 'الأهداف والعمولات', path: '/commissions', ready: false },
  { code: 'P14b', name: 'الأشهر والإغلاق', module: 'الأهداف والعمولات', path: '/months', ready: false },
  { code: 'P15', name: 'خريطة الفواتير والمسار', module: 'الخرائط', path: '/map', ready: false },
  { code: 'P16', name: 'مواقع العملاء', module: 'الخرائط', path: '/locations', ready: false },
  { code: 'P17', name: 'المناطق والأسواق', module: 'الخرائط', path: '/regions', ready: false },
  { code: 'P17a', name: 'مقارنة الفترات', module: 'الخرائط', path: '/compare', ready: false },
  { code: 'P17b', name: 'انتشار الأصناف', module: 'الخرائط', path: '/spread', ready: false },
  { code: 'P18', name: 'التقارير', module: 'التقارير', path: '/reports', ready: false },
  { code: 'P19', name: 'التقويم', module: 'الإعدادات', path: '/calendar', ready: false },
  { code: 'P20', name: 'المستخدمون والصلاحيات', module: 'الإعدادات', path: '/users', ready: true },
  { code: 'P21', name: 'الإعدادات وسجل العمليات', module: 'الإعدادات', path: '/settings', ready: true },
];

export const MODULES = ['البيانات', 'الحسابات', 'الأهداف والعمولات', 'الخرائط', 'التقارير', 'الإعدادات'];

export const ACTION_LABELS: Record<string, string> = {
  view: 'عرض', add: 'إضافة', edit: 'تعديل', delete: 'حذف', import: 'استيراد', export: 'تصدير', print: 'طباعة',
  approve: 'اعتماد', recalc: 'إعادة حساب', snapshot: 'حفظ صورة', transfer: 'نقل', view_cost: 'رؤية التكلفة',
  view_commission: 'رؤية نسب العمولة',
};

export const SCOPE_LABELS: Record<string, string> = {
  all: 'الكل', team: 'فريق المشرف', selected: 'مندوبون مختارون', self: 'الذات فقط',
};
