//  KeePassium Password Manager
//  Copyright © 2018–2022 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import KeePassiumLib

protocol CrashReportDelegate: AnyObject {
    func didPressDismiss(in crashReport: CrashReportVC)
}

final class CrashReportVC: UIViewController {
    @IBOutlet weak var learnMoreButton: UIButton!
    
    public weak var delegate: CrashReportDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()

        learnMoreButton.setTitle(LString.actionLearnMore, for: .normal)
    }
    
    @IBAction func didPressDismiss(_ sender: Any) {
        delegate?.didPressDismiss(in: self)
    }
    
    @IBAction func didPressLearnMore(_ sender: UIButton) {
        let urlOpener = URLOpener(self)
        urlOpener.open(url: URL.AppHelp.autoFillMemoryLimits)
    }
}
