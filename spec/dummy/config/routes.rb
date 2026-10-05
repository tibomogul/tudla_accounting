Rails.application.routes.draw do
  mount TudlaAccounting::Engine => "/tudla_accounting"

  resource :session, only: %i[new create destroy]

  root to: 'pages#home'
end
