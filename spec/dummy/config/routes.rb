Rails.application.routes.draw do
  mount TudlaAccounting::Engine => "/tudla_accounting"

  resource :session, only: %i[new create destroy]

  if Rails.configuration.x.demo
    namespace :demo do
      resource :session, only: :create # opens the seeded demo books
    end
  end

  root to: 'pages#home'
end
