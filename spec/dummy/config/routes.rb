Rails.application.routes.draw do
  mount TudlaAccounting::Engine => "/tudla_accounting"

  root to: 'pages#home'
end
