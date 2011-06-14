class ImportController < ApplicationController
  def index
  end

  def import
    if Wagn::Cardlib::Import.csv( :cardtype=>params[:cardtype], :data=>params[:data] )
      flash[:notice] = "Imported. Woooo!"
      redirect_to '/recent'
    end
  end
end
